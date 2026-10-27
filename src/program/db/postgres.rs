//! PostgreSQL, through the blocking client of `postgres` with TLS by rustls.
//!
//! Every statement runs in a transaction of its own. Unless the person asked to write (`--write`) the
//! transaction is `READ ONLY` and is rolled back after, so it is the server that refuses a write and
//! nothing a statement sets outlives it. A query is read through a cursor, as many rows as are kept
//! and one more: a `select *` of a large table costs the rows shown, not the table. Values come as
//! the server writes them (the simple protocol's text); the types come from preparing the statement.

use std::str::FromStr;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use postgres::config::Host;
use postgres::error::ErrorPosition;
use postgres::types::Type;
use postgres::{CancelToken, Client, Config, SimpleQueryMessage};
use serde_json::Value;
use tokio_postgres_rustls::MakeRustlsConnect;

use super::{
    Column, Failure, Info, Outcome, ROW_CAP, SchemaColumn, Step, Table, timeout, too_long, verb_of,
    watched,
};

/// What a cursor for a statement is declared with; a mistake's place in the statement is counted
/// past it.
const CURSOR: &str = "declare sqlpen_rows no scroll cursor for ";
const EXPLAIN: &str = "explain (format json) ";
const EXPLAIN_ANALYZE: &str = "explain (format json, analyze) ";

const TABLES: &str = "select n.nspname, c.relname, c.relkind::text, c.reltuples::float8, a.attname, \
    format_type(a.atttypid, a.atttypmod), a.attnotnull, coalesce(i.indisprimary, false), \
    pg_table_is_visible(c.oid) \
    from pg_class c \
    join pg_namespace n on n.oid = c.relnamespace \
    join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped \
    left join pg_index i on i.indrelid = c.oid and i.indisprimary and a.attnum = any(i.indkey) \
    where c.relkind in ('r', 'v', 'm', 'p', 'f') \
      and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg_toast%' \
      and has_schema_privilege(n.oid, 'USAGE') \
    order by n.nspname, c.relname, a.attnum";

/// The relations a statement can name, for the hint of one it named that is not on its path.
const ELSEWHERE: &str = "select n.nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace \
    where c.relname = $1 and c.relkind in ('r', 'v', 'm', 'p', 'f') \
      and has_schema_privilege(n.oid, 'USAGE') order by n.nspname";

pub struct Postgres {
    client: Mutex<Client>,
    /// What stops what the connection runs: its own, so that it is not held by the statement.
    cancel: Mutex<CancelToken>,
    config: Config,
    tls: MakeRustlsConnect,
    database: String,
    place: String,
    read_only: bool,
}

impl Postgres {
    /// Connects to the database a connection string names (`postgres://…`, or `host=… dbname=…`).
    pub fn connect(address: &str, write: bool) -> Result<Self, Failure> {
        let mut config = Config::from_str(address).map_err(|why| {
            Failure::new(format!("That is not a PostgreSQL connection string: {why}"))
        })?;
        config.application_name("sqlpen");
        if config.get_connect_timeout().is_none() {
            config.connect_timeout(Duration::from_secs(10));
        }
        let tls = tls()?;
        let client = open(&config, &tls, !write)?;
        let cancel = client.cancel_token();
        Ok(Self {
            client: Mutex::new(client),
            cancel: Mutex::new(cancel),
            database: config.get_dbname().unwrap_or("").to_owned(),
            place: place_of(&config),
            config,
            tls,
            read_only: !write,
        })
    }

    /// The connection, connected again first if the server closed it (it restarted, a proxy let go
    /// of an idle connection): a person whose statement found it closed runs it again and it runs.
    fn client(&self) -> Result<std::sync::MutexGuard<'_, Client>, Failure> {
        let mut client = self.client.lock().unwrap_or_else(PoisonError::into_inner);
        if client.is_closed() {
            *client = open(&self.config, &self.tls, self.read_only)?;
            *self.cancel.lock().unwrap_or_else(PoisonError::into_inner) = client.cancel_token();
        }
        Ok(client)
    }

    pub fn info(&self) -> Result<Info, Failure> {
        let mut client = self.client()?;
        let row = client
            .query_one(
                "select current_setting('server_version'), current_database()",
                &[],
            )
            .map_err(|why| failure_of(&why, 0))?;
        let version: String = row.get(0);
        let database: String = row.get(1);
        Ok(Info {
            engine: "postgres",
            version: format!(
                "PostgreSQL {}",
                version.split_whitespace().next().unwrap_or(&version)
            ),
            database: if database.is_empty() {
                self.database.clone()
            } else {
                database
            },
            place: self.place.clone(),
            read_only: self.read_only,
        })
    }

    pub fn tables(&self) -> Result<Vec<Table>, Failure> {
        let mut client = self.client()?;
        let rows = client
            .query(TABLES, &[])
            .map_err(|why| failure_of(&why, 0))?;
        let mut tables: Vec<Table> = Vec::new();
        for row in rows {
            let schema: String = row.get(0);
            let name: String = row.get(1);
            let column = SchemaColumn {
                name: row.get(4),
                kind: row.get(5),
                nullable: !row.get::<_, bool>(6),
                key: row.get(7),
            };
            match tables.last_mut() {
                Some(table) if table.schema == schema && table.name == name => {
                    table.columns.push(column)
                }
                _ => {
                    let kind: String = row.get(2);
                    let estimate: f64 = row.get(3);
                    tables.push(Table {
                        schema,
                        name,
                        kind: if kind == "r" || kind == "p" || kind == "f" {
                            "table"
                        } else {
                            "view"
                        },
                        // A table never analysed says -1: not known.
                        rows: (estimate >= 0.0 && kind != "v").then_some(estimate.round() as i64),
                        columns: vec![column],
                        visible: row.get(8),
                    });
                }
            }
        }
        Ok(tables)
    }

    pub fn run(&self, sql: &str, stop: &(dyn Fn() -> bool + Sync)) -> Result<Outcome, Failure> {
        let mut client = self.client()?;
        let read_only = self.read_only;
        let (result, timed_out) = watched(
            stop,
            || self.stop_now(),
            || run_on(&mut client, sql, read_only),
        );
        result.map_err(|failure| self.explained(&mut client, failure, timed_out))
    }

    pub fn explain(
        &self,
        sql: &str,
        analyze: bool,
        stop: &(dyn Fn() -> bool + Sync),
    ) -> Result<Step, Failure> {
        let mut client = self.client()?;
        let (result, timed_out) = watched(
            stop,
            || self.stop_now(),
            || plan_on(&mut client, sql, analyze),
        );
        result.map_err(|failure| self.explained(&mut client, failure, timed_out))
    }

    /// Asks the server, on a connection of its own, to stop what this one is running.
    fn stop_now(&self) {
        let cancel = self
            .cancel
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        let _ = cancel.cancel_query(self.tls.clone());
    }

    /// A failure with what sqlpen knows of it besides: that it was stopped, that the database is
    /// read only, where a relation it did not find is.
    fn explained(&self, client: &mut Client, mut failure: Failure, timed_out: bool) -> Failure {
        match failure.code.as_deref() {
            // Canceled: by the person, or by the time a statement may take.
            Some("57014") => {
                failure.message = if timed_out {
                    too_long()
                } else {
                    "It was stopped".to_owned()
                };
            }
            Some("25006") if self.read_only => {
                failure.hint = Some(
                    "sqlpen opens a database read only: run it with --write to change this one"
                        .into(),
                );
            }
            // `relation "customers" does not exist`: it may be in a schema not on the path.
            Some("42P01") if failure.hint.is_none() => {
                let name = failure.message.split('"').nth(1).map(str::to_owned);
                if let Some(name) = name.filter(|name| !name.contains('.')) {
                    let schemas: Vec<String> = client
                        .query(ELSEWHERE, &[&name])
                        .map(|rows| rows.iter().map(|row| row.get(0)).collect())
                        .unwrap_or_default();
                    if let Some(first) = schemas.first() {
                        let places: Vec<String> = schemas
                            .iter()
                            .map(|schema| format!("{schema}.{name}"))
                            .collect();
                        failure.hint = Some(format!(
                            "It is in schema {first}, which is not on the search path: write {}, or set search_path to {first}",
                            places.join(" or ")
                        ));
                    }
                }
            }
            _ => {}
        }
        failure
    }
}

/// A connection, read only unless the person asked to write.
fn open(config: &Config, tls: &MakeRustlsConnect, read_only: bool) -> Result<Client, Failure> {
    let mut client = config
        .connect(tls.clone())
        .map_err(|why| failure_of(&why, 0))?;
    if read_only {
        // Every transaction read only, the ones a statement starts itself too.
        client
            .batch_execute("set default_transaction_read_only = on")
            .map_err(|why| failure_of(&why, 0))?;
    }
    Ok(client)
}

fn run_on(client: &mut Client, sql: &str, read_only: bool) -> Result<Outcome, Failure> {
    let started = Instant::now();
    let verb = verb_of(sql);
    let reads = matches!(verb.as_str(), "SELECT" | "WITH" | "VALUES" | "TABLE");
    if !read_only && !reads {
        // A write runs as the person wrote it: outside a transaction of ours, so that what cannot run
        // in one (VACUUM, CREATE INDEX CONCURRENTLY) does, and what it does is done.
        client
            .batch_execute(&timeout_for(false))
            .map_err(|why| failure_of(&why, 0))?;
        let messages = client
            .simple_query(sql)
            .map_err(|why| failure_of(&why, 0))?;
        return Ok(outcome_of(&messages, None, &verb, started));
    }
    let mut transaction = client
        .build_transaction()
        .read_only(read_only)
        .start()
        .map_err(|why| failure_of(&why, 0))?;
    transaction
        .batch_execute(&timeout_for(true))
        .map_err(|why| failure_of(&why, 0))?;
    let types = types_of(&mut transaction, sql);
    let result = if reads && types.is_some() {
        read_through_cursor(&mut transaction, sql, types.as_deref(), &verb, started)
    } else {
        transaction
            .simple_query(sql)
            .map(|messages| outcome_of(&messages, types.as_deref(), &verb, started))
            .map_err(|why| failure_of(&why, 0))
    };
    // A read is rolled back (nothing it set stays); a write that went is kept.
    let ended = if read_only || result.is_err() {
        transaction.rollback()
    } else {
        transaction.commit()
    };
    let outcome = result?;
    ended.map_err(|why| failure_of(&why, 0))?;
    Ok(outcome)
}

/// The rows of a query, through a cursor: as many as are kept and one more, to know it was cut. A
/// statement no cursor can be declared for (a `WITH` that writes) is run as it is instead.
fn read_through_cursor(
    transaction: &mut postgres::Transaction<'_>,
    sql: &str,
    types: Option<&[(String, Type)]>,
    verb: &str,
    started: Instant,
) -> Result<Outcome, Failure> {
    let mut point = transaction
        .savepoint("sqlpen_cursor")
        .map_err(|why| failure_of(&why, 0))?;
    match point.batch_execute(&format!("{CURSOR}{sql}")) {
        Ok(()) => {
            let messages = point
                .simple_query(&format!("fetch {} from sqlpen_rows", ROW_CAP + 1))
                .map_err(|why| failure_of(&why, 0))?;
            // `outcome_of` keeps one row past the cap to know the result was cut.
            let mut outcome = outcome_of(&messages, types, verb, started);
            outcome.tag = format!(
                "{verb} {}{}",
                outcome.rows.len(),
                if outcome.cut { "+" } else { "" }
            );
            // The cursor goes with the transaction; the savepoint is let go to keep it simple.
            let _ = point.commit();
            Ok(outcome)
        }
        Err(why) => {
            let failure = failure_of(&why, CURSOR.chars().count());
            let _ = point.rollback();
            // A mistake in the statement is the person's; only what a cursor cannot hold is run again.
            if failure.code.as_deref() == Some("0A000") {
                transaction
                    .simple_query(sql)
                    .map(|messages| outcome_of(&messages, types, verb, started))
                    .map_err(|why| failure_of(&why, 0))
            } else {
                Err(failure)
            }
        }
    }
}

/// The columns and types of a statement, by preparing it in a savepoint (a statement that cannot be
/// prepared, several statements at once, leaves the transaction as it was).
fn types_of(transaction: &mut postgres::Transaction<'_>, sql: &str) -> Option<Vec<(String, Type)>> {
    let mut point = transaction.savepoint("sqlpen_types").ok()?;
    let types = point.prepare(sql).ok().map(|statement| {
        statement
            .columns()
            .iter()
            .map(|column| (column.name().to_owned(), column.type_().clone()))
            .collect()
    });
    let _ = point.rollback();
    types
}

fn timeout_for(local: bool) -> String {
    format!(
        "set {}statement_timeout = '{}s'",
        if local { "local " } else { "" },
        timeout().as_secs() + 1
    )
}

/// What the messages of a statement say: the rows of the last result that had rows, and the tag.
fn outcome_of(
    messages: &[SimpleQueryMessage],
    types: Option<&[(String, Type)]>,
    verb: &str,
    started: Instant,
) -> Outcome {
    let mut columns: Option<Vec<Column>> = None;
    let mut rows = Vec::new();
    let mut count = None;
    for message in messages {
        match message {
            SimpleQueryMessage::RowDescription(described) => {
                rows.clear();
                columns = Some(
                    described
                        .iter()
                        .enumerate()
                        .map(|(index, column)| {
                            let typed = types
                                .filter(|types| types.len() == described.len())
                                .and_then(|types| types.get(index));
                            Column {
                                name: column.name().to_owned(),
                                kind: typed
                                    .map_or_else(String::new, |(_, kind)| kind.name().to_owned()),
                                numeric: typed.is_some_and(|(_, kind)| numeric(kind)),
                            }
                        })
                        .collect(),
                );
            }
            SimpleQueryMessage::Row(row) => {
                if rows.len() <= ROW_CAP {
                    rows.push(
                        (0..row.len())
                            .map(|index| row.get(index).map(str::to_owned))
                            .collect(),
                    );
                }
            }
            SimpleQueryMessage::CommandComplete(changed) => count = Some(*changed),
            _ => {}
        }
    }
    let cut = rows.len() > ROW_CAP;
    rows.truncate(ROW_CAP);
    let tag = match (&columns, count) {
        (Some(_), Some(count)) => format!("{verb} {count}"),
        (None, Some(count))
            if matches!(verb, "INSERT" | "UPDATE" | "DELETE" | "MERGE" | "COPY") =>
        {
            format!("{verb} {count}")
        }
        _ => verb.to_owned(),
    };
    Outcome {
        columns: columns.unwrap_or_default(),
        rows,
        cut,
        tag,
        elapsed: started.elapsed(),
    }
}

fn numeric(kind: &Type) -> bool {
    [
        Type::INT2,
        Type::INT4,
        Type::INT8,
        Type::FLOAT4,
        Type::FLOAT8,
        Type::NUMERIC,
        Type::OID,
        Type::MONEY,
    ]
    .contains(kind)
}

fn plan_on(client: &mut Client, sql: &str, analyze: bool) -> Result<Step, Failure> {
    let prefix = if analyze { EXPLAIN_ANALYZE } else { EXPLAIN };
    let mut transaction = client.transaction().map_err(|why| failure_of(&why, 0))?;
    transaction
        .batch_execute(&timeout_for(true))
        .map_err(|why| failure_of(&why, 0))?;
    let messages = transaction
        .simple_query(&format!("{prefix}{sql}"))
        .map_err(|why| failure_of(&why, prefix.chars().count()));
    // An ANALYZE runs the statement: whatever it did is not kept.
    let _ = transaction.rollback();
    let text = messages?
        .iter()
        .find_map(|message| match message {
            SimpleQueryMessage::Row(row) => row.get(0).map(str::to_owned),
            _ => None,
        })
        .ok_or_else(|| Failure::new("The server gave no plan"))?;
    let plan: Value = serde_json::from_str(&text)
        .map_err(|why| Failure::new(format!("The plan is not JSON: {why}")))?;
    let top = plan
        .get(0)
        .ok_or_else(|| Failure::new("The server gave no plan"))?;
    let mut detail = Vec::new();
    for (key, words) in [
        ("Planning Time", "planning"),
        ("Execution Time", "execution"),
    ] {
        if let Some(ms) = top.get(key).and_then(Value::as_f64) {
            detail.push(format!("{words} {ms:.2} ms"));
        }
    }
    Ok(Step {
        label: "QUERY PLAN".to_owned(),
        detail,
        children: top.get("Plan").map(step_of).into_iter().collect(),
        ..Step::default()
    })
}

/// A node of PostgreSQL's plan as a step: what it does and on what, its conditions, its costs.
fn step_of(node: &Value) -> Step {
    let text = |key: &str| node.get(key).and_then(Value::as_str);
    let number = |key: &str| node.get(key).and_then(Value::as_f64);
    let mut label = text("Node Type").unwrap_or("?").to_owned();
    if let Some(join) =
        text("Join Type").filter(|_| label.contains("Join") || label == "Nested Loop")
    {
        label = format!("{join} {label}");
    }
    if let Some(index) = text("Index Name") {
        label = format!("{label} using {index}");
    }
    if let Some(relation) = text("Relation Name") {
        label = format!("{label} on {relation}");
        if let Some(alias) = text("Alias").filter(|alias| *alias != relation) {
            label = format!("{label} {alias}");
        }
    }
    let mut detail = Vec::new();
    for key in [
        "Index Cond",
        "Filter",
        "Hash Cond",
        "Merge Cond",
        "Join Filter",
        "Recheck Cond",
    ] {
        if let Some(words) = text(key) {
            detail.push(format!("{}: {words}", key.to_lowercase()));
        }
    }
    for key in ["Sort Key", "Group Key"] {
        if let Some(keys) = node.get(key).and_then(Value::as_array) {
            let keys: Vec<&str> = keys.iter().filter_map(Value::as_str).collect();
            detail.push(format!("{}: {}", key.to_lowercase(), keys.join(", ")));
        }
    }
    if let Some(removed) = number("Rows Removed by Filter").filter(|removed| *removed > 0.0) {
        detail.push(format!("rows removed by filter: {removed}"));
    }
    let loops = number("Actual Loops").unwrap_or(1.0);
    Step {
        label,
        detail,
        cost: number("Total Cost"),
        rows: number("Plan Rows"),
        time: number("Actual Total Time").map(|ms| ms * loops),
        actual_rows: number("Actual Rows").map(|rows| rows * loops),
        children: node
            .get("Plans")
            .and_then(Value::as_array)
            .map(|plans| plans.iter().map(step_of).collect())
            .unwrap_or_default(),
    }
}

/// Where the database is, as the page may show it: the user, the host and the port, and never a
/// password.
fn place_of(config: &Config) -> String {
    let user = config.get_user().unwrap_or("");
    let host = match config.get_hosts().first() {
        Some(Host::Tcp(name)) => name.clone(),
        #[cfg(unix)]
        Some(Host::Unix(path)) => path.display().to_string(),
        None => "localhost".to_owned(),
    };
    let port = config.get_ports().first().copied().unwrap_or(5432);
    if user.is_empty() {
        format!("{host}:{port}")
    } else {
        format!("{user}@{host}:{port}")
    }
}

fn tls() -> Result<MakeRustlsConnect, Failure> {
    let mut roots = rustls::RootCertStore::empty();
    for certificate in rustls_native_certs::load_native_certs().certs {
        let _ = roots.add(certificate);
    }
    let config = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .map_err(|why| Failure::new(format!("TLS: {why}")))?
    .with_root_certificates(roots)
    .with_no_client_auth();
    Ok(MakeRustlsConnect::new(config))
}

/// What the server said, as the page shows it; a place in the statement it points at, counted from 0
/// and back past `shift` characters sqlpen put before the statement.
fn failure_of(why: &postgres::Error, shift: usize) -> Failure {
    if let Some(db) = why.as_db_error() {
        let position = match db.position() {
            Some(ErrorPosition::Original(at)) => usize::try_from(*at)
                .ok()
                .and_then(|at| at.checked_sub(1 + shift)),
            _ => None,
        };
        return Failure {
            message: db.message().to_owned(),
            detail: db.detail().map(str::to_owned),
            hint: db.hint().map(str::to_owned),
            position,
            code: Some(db.code().code().to_owned()),
        };
    }
    // The client's own words are terse ("error connecting to server"): the reason is in its sources.
    let mut message = why.to_string();
    let mut source = std::error::Error::source(why);
    while let Some(cause) = source {
        let words = cause.to_string();
        if !message.contains(&words) {
            message = format!("{message}: {words}");
        }
        source = cause.source();
    }
    Failure::new(message)
}

#[cfg(test)]
mod tests {
    //! Against a real server, where `SQLPEN_TEST_PG` names one (the demo's `docker run`, README);
    //! without it they say so and pass.
    use super::*;

    fn server() -> Option<Postgres> {
        let address = std::env::var("SQLPEN_TEST_PG").ok()?;
        Some(Postgres::connect(&address, false).unwrap())
    }

    fn never() -> bool {
        false
    }

    #[test]
    fn a_server_says_what_it_is_and_what_it_holds() {
        let Some(db) = server() else {
            eprintln!("SQLPEN_TEST_PG is not set: skipped");
            return;
        };
        let info = db.info().unwrap();
        assert!(info.version.starts_with("PostgreSQL "));
        assert!(
            !info.place.contains("reader:"),
            "no password in {}",
            info.place
        );
        let tables = db.tables().unwrap();
        let orders = tables.iter().find(|table| table.name == "orders").unwrap();
        assert_eq!(orders.schema, "shop");
        assert!(orders.rows.unwrap_or(0) > 0);
        assert!(
            orders
                .columns
                .iter()
                .any(|column| column.name == "id" && column.key)
        );
    }

    #[test]
    fn a_query_is_read_through_a_cursor_and_cut_at_the_cap() {
        let Some(db) = server() else {
            eprintln!("SQLPEN_TEST_PG is not set: skipped");
            return;
        };
        let outcome = db
            .run(
                "select id, total, status from shop.orders order by id",
                &never,
            )
            .unwrap();
        assert_eq!(outcome.rows.len(), ROW_CAP);
        assert!(outcome.cut);
        assert_eq!(outcome.tag, format!("SELECT {ROW_CAP}+"));
        assert!(
            outcome.columns[0].numeric && outcome.columns[1].numeric && !outcome.columns[2].numeric
        );
        assert_eq!(outcome.columns[1].kind, "numeric");
    }

    #[test]
    fn a_write_is_refused_and_a_mistake_says_where_it_is() {
        let Some(db) = server() else {
            eprintln!("SQLPEN_TEST_PG is not set: skipped");
            return;
        };
        let refused = db
            .run("update shop.orders set total = 0", &never)
            .unwrap_err();
        assert_eq!(refused.code.as_deref(), Some("25006"), "{refused:?}");
        let mistake = db
            .run("select nme from shop.customers", &never)
            .unwrap_err();
        assert_eq!(mistake.position, Some(7), "{mistake:?}");
        // The connection is fine after both.
        assert_eq!(
            db.run("select 1", &never).unwrap().rows,
            vec![vec![Some("1".to_owned())]]
        );
    }

    #[test]
    fn a_table_off_the_search_path_is_said_where_it_is() {
        let Some(db) = server() else {
            eprintln!("SQLPEN_TEST_PG is not set: skipped");
            return;
        };
        let tables = db.tables().unwrap();
        let customers = tables
            .iter()
            .find(|table| table.name == "customers")
            .unwrap();
        assert!(!customers.visible, "shop is not on the reader's path");
        let failure = db.run("select * from customers", &never).unwrap_err();
        assert_eq!(failure.code.as_deref(), Some("42P01"));
        assert!(failure.hint.unwrap().contains("shop.customers"));
    }

    #[test]
    fn a_statement_is_stopped_when_asked() {
        let Some(db) = server() else {
            eprintln!("SQLPEN_TEST_PG is not set: skipped");
            return;
        };
        let started = Instant::now();
        let stop = || started.elapsed() > Duration::from_millis(200);
        let failure = db.run("select pg_sleep(5)", &stop).unwrap_err();
        assert_eq!(failure.message, "It was stopped");
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    #[test]
    fn a_plan_names_its_steps_and_their_costs() {
        let Some(db) = server() else {
            eprintln!("SQLPEN_TEST_PG is not set: skipped");
            return;
        };
        let plan = db
            .explain(
                "select c.name, count(*) from shop.orders o join shop.customers c on c.id = o.customer_id group by 1",
                true,
                &never,
            )
            .unwrap();
        let top = &plan.children[0];
        assert!(top.cost.is_some() && top.time.is_some(), "{top:?}");
        assert!(
            plan.detail
                .iter()
                .any(|words| words.starts_with("execution"))
        );
    }
}
