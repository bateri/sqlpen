//! SQLite, through the library built into the program: a file, or the demo's shop in memory.
//!
//! A database is opened read only unless the person asked to write (`--write`): the file is opened
//! for reading and the connection says `query_only`, so it is SQLite that refuses a write, not a
//! guess of ours at what a statement does.

use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use rusqlite::types::ValueRef;
use rusqlite::{Connection, InterruptHandle, OpenFlags};

use super::{Column, Failure, Info, Outcome, ROW_CAP, SchemaColumn, Step, Table, verb_of, watched};

/// The shop of `sqlpen --demo`.
const DEMO: &str = include_str!("../../../demo/sqlite.sql");
/// How long counting the rows of the tables for the list of them may take, all of them together.
const COUNTING: Duration = Duration::from_millis(300);

pub struct Sqlite {
    connection: Mutex<Connection>,
    interrupt: InterruptHandle,
    /// The file, or none for the demo's database in memory.
    path: Option<PathBuf>,
    read_only: bool,
}

impl Sqlite {
    /// The database in the file at `path`, which must be there.
    pub fn open(path: &Path, write: bool) -> Result<Self, Failure> {
        if !path.is_file() {
            return Err(Failure::new(format!(
                "There is no database at {}",
                path.display()
            )));
        }
        let flags = if write {
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX
        } else {
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX
        };
        let connection =
            Connection::open_with_flags(path, flags).map_err(|why| failure_of(&why, ""))?;
        Self::with(connection, Some(path.to_path_buf()), write)
    }

    /// The demo's shop, made in memory now.
    pub fn demo(write: bool) -> Result<Self, Failure> {
        let connection = Connection::open_in_memory().map_err(|why| failure_of(&why, ""))?;
        connection
            .execute_batch(DEMO)
            .map_err(|why| failure_of(&why, DEMO))?;
        Self::with(connection, None, write)
    }

    fn with(connection: Connection, path: Option<PathBuf>, write: bool) -> Result<Self, Failure> {
        // A file another program writes to answers "busy" for a moment, not at once.
        connection
            .busy_timeout(Duration::from_secs(2))
            .map_err(|why| failure_of(&why, ""))?;
        if !write {
            connection
                .pragma_update(None, "query_only", true)
                .map_err(|why| failure_of(&why, ""))?;
        }
        let interrupt = connection.get_interrupt_handle();
        Ok(Self {
            connection: Mutex::new(connection),
            interrupt,
            path,
            read_only: !write,
        })
    }

    fn connection(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.connection
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }

    pub fn info(&self) -> Result<Info, Failure> {
        let version: String = self
            .connection()
            .query_row("select sqlite_version()", [], |row| row.get(0))
            .map_err(|why| failure_of(&why, ""))?;
        let (database, place) = match &self.path {
            Some(path) => (
                path.file_name().map_or_else(
                    || path.display().to_string(),
                    |name| name.to_string_lossy().into_owned(),
                ),
                path.display().to_string(),
            ),
            None => ("demo".to_owned(), "in memory".to_owned()),
        };
        Ok(Info {
            engine: "sqlite",
            version: format!("SQLite {version}"),
            database,
            place,
            read_only: self.read_only,
        })
    }

    pub fn tables(&self) -> Result<Vec<Table>, Failure> {
        let connection = self.connection();
        let fail = |why: rusqlite::Error| failure_of(&why, "");
        let mut statement = connection
            .prepare(
                "select name, type from main.sqlite_schema where type in ('table', 'view') \
                 and name not like 'sqlite_%' order by name",
            )
            .map_err(fail)?;
        let names: Vec<(String, String)> = statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(fail)?
            .collect::<Result<_, _>>()
            .map_err(fail)?;
        let started = Instant::now();
        let mut tables = Vec::with_capacity(names.len());
        for (name, kind) in names {
            let mut columns = connection
                .prepare("select name, type, \"notnull\", pk from pragma_table_info(?1)")
                .map_err(fail)?;
            let columns: Vec<SchemaColumn> = columns
                .query_map([&name], |row| {
                    Ok(SchemaColumn {
                        name: row.get(0)?,
                        kind: row.get(1)?,
                        nullable: row.get::<_, i64>(2)? == 0,
                        key: row.get::<_, i64>(3)? > 0,
                    })
                })
                .map_err(fail)?
                .collect::<Result<_, _>>()
                .map_err(fail)?;
            // Counting is a scan: the tables are counted while it is cheap, and those after are not.
            let rows = if kind == "table" && started.elapsed() < COUNTING {
                connection
                    .query_row(
                        &format!("select count(*) from \"{}\"", name.replace('"', "\"\"")),
                        [],
                        |row| row.get(0),
                    )
                    .ok()
            } else {
                None
            };
            tables.push(Table {
                schema: "main".to_owned(),
                name,
                kind: if kind == "view" { "view" } else { "table" },
                rows,
                columns,
                visible: true,
            });
        }
        Ok(tables)
    }

    pub fn run(&self, sql: &str, stop: &(dyn Fn() -> bool + Sync)) -> Result<Outcome, Failure> {
        let connection = self.connection();
        let (result, timed_out) = watched(
            stop,
            || self.interrupt.interrupt(),
            || run_on(&connection, sql),
        );
        result.map_err(|failure| self.explained(failure, timed_out))
    }

    pub fn explain(&self, sql: &str, stop: &(dyn Fn() -> bool + Sync)) -> Result<Step, Failure> {
        let connection = self.connection();
        let (result, timed_out) = watched(
            stop,
            || self.interrupt.interrupt(),
            || plan_on(&connection, sql),
        );
        result.map_err(|failure| self.explained(failure, timed_out))
    }

    /// A failure with what sqlpen knows of it besides: that it was stopped, that the database is
    /// read only.
    fn explained(&self, mut failure: Failure, timed_out: bool) -> Failure {
        if failure.code.as_deref() == Some("SQLITE_INTERRUPT") {
            failure.message = if timed_out {
                super::too_long()
            } else {
                "It was stopped".to_owned()
            };
        }
        if self.read_only && failure.message.contains("readonly") {
            failure.hint = Some(
                "sqlpen opens a database read only: run it with --write to change this one".into(),
            );
        }
        failure
    }
}

fn run_on(connection: &Connection, sql: &str) -> Result<Outcome, Failure> {
    let started = Instant::now();
    let mut statement = connection
        .prepare(sql)
        .map_err(|why| failure_of(&why, sql))?;
    let count = statement.column_count();
    if count == 0 {
        let changed = statement.execute([]).map_err(|why| failure_of(&why, sql))?;
        let verb = verb_of(sql);
        let tag = match verb.as_str() {
            "INSERT" | "UPDATE" | "DELETE" | "REPLACE" => format!("{verb} {changed}"),
            _ => verb,
        };
        return Ok(Outcome {
            tag,
            elapsed: started.elapsed(),
            ..Outcome::default()
        });
    }
    let declared: Vec<(String, String)> = statement
        .columns()
        .iter()
        .map(|column| {
            (
                column.name().to_owned(),
                column.decl_type().unwrap_or("").to_owned(),
            )
        })
        .collect();
    let mut seen: Vec<Option<&'static str>> = vec![None; count];
    let mut kept = Vec::new();
    let mut cut = false;
    let mut rows = statement.raw_query();
    while let Some(row) = rows.next().map_err(|why| failure_of(&why, sql))? {
        if kept.len() == ROW_CAP {
            cut = true;
            break;
        }
        let mut values = Vec::with_capacity(count);
        for (index, seen) in seen.iter_mut().enumerate() {
            let value = row.get_ref(index).map_err(|why| failure_of(&why, sql))?;
            if seen.is_none() {
                *seen = kind_of(value);
            }
            values.push(text_of(value));
        }
        kept.push(values);
    }
    let columns = declared
        .into_iter()
        .zip(seen)
        .map(|((name, declared), seen)| {
            let numeric = if declared.is_empty() {
                matches!(seen, Some("integer" | "real"))
            } else {
                numeric_declared(&declared)
            };
            let kind = if declared.is_empty() {
                seen.unwrap_or("").to_owned()
            } else {
                declared
            };
            Column {
                name,
                kind,
                numeric,
            }
        })
        .collect();
    let tag = format!("{} {}", verb_of(sql), kept.len());
    Ok(Outcome {
        columns,
        rows: kept,
        cut,
        tag,
        elapsed: started.elapsed(),
    })
}

fn plan_on(connection: &Connection, sql: &str) -> Result<Step, Failure> {
    let explain = format!("explain query plan {sql}");
    let mut statement = connection
        .prepare(&explain)
        .map_err(|why| shifted(failure_of(&why, &explain), "explain query plan ".len()))?;
    let lines: Vec<(i64, i64, String)> = statement
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(3)?)))
        .map_err(|why| failure_of(&why, sql))?
        .collect::<Result<_, _>>()
        .map_err(|why| failure_of(&why, sql))?;
    fn under(parent: i64, lines: &[(i64, i64, String)]) -> Vec<Step> {
        lines
            .iter()
            .filter(|(_, of, _)| *of == parent)
            .map(|(id, _, detail)| Step {
                label: detail.clone(),
                children: under(*id, lines),
                ..Step::default()
            })
            .collect()
    }
    Ok(Step {
        label: "QUERY PLAN".to_owned(),
        children: under(0, &lines),
        ..Step::default()
    })
}

/// A failure of a statement that was asked with something before it: its place moved back.
fn shifted(mut failure: Failure, by: usize) -> Failure {
    failure.position = failure.position.and_then(|at| at.checked_sub(by));
    failure
}

fn numeric_declared(declared: &str) -> bool {
    let upper = declared.to_uppercase();
    ["INT", "REAL", "FLOA", "DOUB", "NUM", "DEC"]
        .iter()
        .any(|word| upper.contains(word))
}

fn kind_of(value: ValueRef<'_>) -> Option<&'static str> {
    match value {
        ValueRef::Null => None,
        ValueRef::Integer(_) => Some("integer"),
        ValueRef::Real(_) => Some("real"),
        ValueRef::Text(_) => Some("text"),
        ValueRef::Blob(_) => Some("blob"),
    }
}

fn text_of(value: ValueRef<'_>) -> Option<String> {
    match value {
        ValueRef::Null => None,
        ValueRef::Integer(number) => Some(number.to_string()),
        ValueRef::Real(number) => Some(number.to_string()),
        ValueRef::Text(bytes) => Some(String::from_utf8_lossy(bytes).into_owned()),
        ValueRef::Blob(bytes) => {
            let shown: String = bytes
                .iter()
                .take(32)
                .map(|byte| format!("{byte:02x}"))
                .collect();
            let more = if bytes.len() > 32 { "…" } else { "" };
            Some(format!("x'{shown}{more}' ({} bytes)", bytes.len()))
        }
    }
}

/// What SQLite said, as the page shows it: the message, its code and the character of the statement
/// it points at.
fn failure_of(why: &rusqlite::Error, sql: &str) -> Failure {
    match why {
        rusqlite::Error::SqlInputError { msg, offset, .. } => Failure {
            message: msg.clone(),
            position: usize::try_from(*offset)
                .ok()
                .and_then(|at| sql.get(..at))
                .map(|before| before.chars().count()),
            // SQLite gives a mistake in a statement no code of its own (`SQLITE_ERROR`): the
            // message and the place say all there is.
            code: None,
            ..Failure::default()
        },
        rusqlite::Error::SqliteFailure(error, message) => Failure {
            message: message.clone().unwrap_or_else(|| error.to_string()),
            code: Some(code_of(error)),
            ..Failure::default()
        },
        rusqlite::Error::MultipleStatement => Failure {
            message: "sqlpen runs one statement at a time: put the caret in the one to run".into(),
            ..Failure::default()
        },
        other => Failure::new(other.to_string()),
    }
}

fn code_of(error: &rusqlite::ffi::Error) -> String {
    if error.code == rusqlite::ErrorCode::OperationInterrupted {
        "SQLITE_INTERRUPT".to_owned()
    } else {
        format!("SQLITE_{:?}", error.code).to_uppercase()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn never() -> bool {
        false
    }

    #[test]
    fn the_demo_has_its_shop_and_says_what_it_is() {
        let db = Sqlite::demo(false).unwrap();
        let info = db.info().unwrap();
        assert_eq!(info.engine, "sqlite");
        assert!(info.read_only);
        let tables = db.tables().unwrap();
        let names: Vec<&str> = tables.iter().map(|table| table.name.as_str()).collect();
        assert_eq!(
            names,
            [
                "customers",
                "events",
                "order_items",
                "orders",
                "products",
                "revenue_by_month"
            ]
        );
        let orders = tables.iter().find(|table| table.name == "orders").unwrap();
        assert_eq!(orders.rows, Some(20_000));
        assert!(
            orders
                .columns
                .iter()
                .any(|column| column.name == "id" && column.key)
        );
        assert_eq!(tables.last().unwrap().kind, "view");
    }

    #[test]
    fn a_query_gives_its_columns_rows_and_tag() {
        let db = Sqlite::demo(false).unwrap();
        let outcome = db
            .run(
                "select id, name, null as missing, 1.5 as half from customers order by id limit 3",
                &never,
            )
            .unwrap();
        assert_eq!(outcome.tag, "SELECT 3");
        assert_eq!(outcome.rows[0][0].as_deref(), Some("1"));
        assert_eq!(outcome.rows[0][1].as_deref(), Some("Deniz Kaya"));
        assert_eq!(outcome.rows[0][2], None);
        assert!(outcome.columns[0].numeric);
        assert!(!outcome.columns[1].numeric);
        assert!(outcome.columns[3].numeric);
    }

    #[test]
    fn a_write_is_refused_where_the_database_is_read_only() {
        let db = Sqlite::demo(false).unwrap();
        let failure = db.run("delete from orders", &never).unwrap_err();
        assert!(failure.message.contains("readonly"), "{failure:?}");
        assert!(failure.hint.unwrap().contains("--write"));
        let db = Sqlite::demo(true).unwrap();
        assert_eq!(
            db.run("delete from events where id <= 10", &never)
                .unwrap()
                .tag,
            "DELETE 10"
        );
    }

    #[test]
    fn a_mistake_says_where_it_is() {
        let db = Sqlite::demo(false).unwrap();
        let failure = db.run("select nme from customers", &never).unwrap_err();
        assert!(failure.message.contains("nme"), "{failure:?}");
        assert_eq!(failure.position, Some(7));
    }

    #[test]
    fn a_long_result_is_cut_at_the_cap() {
        let db = Sqlite::demo(false).unwrap();
        let outcome = db.run("select * from orders", &never).unwrap();
        assert_eq!(outcome.rows.len(), ROW_CAP);
        assert!(outcome.cut);
    }

    #[test]
    fn a_statement_that_is_stopped_says_so() {
        let db = Sqlite::demo(false).unwrap();
        let started = Instant::now();
        let stop = || started.elapsed() > Duration::from_millis(100);
        let failure = db
            .run(
                "with recursive n(g) as (select 1 union all select g + 1 from n) select count(*) from n",
                &stop,
            )
            .unwrap_err();
        assert_eq!(failure.message, "It was stopped");
    }

    #[test]
    fn a_plan_is_a_tree_of_steps() {
        let db = Sqlite::demo(false).unwrap();
        let plan = db
            .explain("select * from orders o join customers c on c.id = o.customer_id where c.country = 'TR'", &never)
            .unwrap();
        assert_eq!(plan.label, "QUERY PLAN");
        assert!(!plan.children.is_empty());
        // SQLite names a table by its alias in a plan.
        assert!(
            plan.children
                .iter()
                .any(|step| step.label.starts_with("SCAN")),
            "{plan:?}"
        );
        assert!(
            plan.children
                .iter()
                .any(|step| step.label.contains("orders_customer")),
            "{plan:?}"
        );
    }
}
