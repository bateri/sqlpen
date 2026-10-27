//! What the page may ask of the program, by name: the calls of its view. They are one function here
//! ([`App::call`]) so that the page's tests ask the same as the terminal's page does.

use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use pencere::ViewError;
use serde_json::{Value, json};

use crate::db::{self, Db, Failure, Results, VALUE_CAP, columns_json, rows_json};

/// The rows of a result that go with it at first, and the most a page may ask for at once; and the
/// bytes of rows a message carries at most, whatever their number (a message is read by the page in
/// one call, held to its time).
const FIRST_ROWS: usize = 200;
const MOST_ROWS: usize = 1_000;
const ROW_BYTES: usize = 20 * 1024;
/// The largest file a page may have read (a dropped `.sql`): what a reply may put in its editor,
/// with room for the JSON around it.
const FILE_CAP: u64 = 512 * 1024;
/// The most text the page is given for the pasteboard, under the 64 KiB a reply may copy.
const COPY_BYTES: usize = 60 * 1024;

/// The calls the page makes.
pub const METHODS: &[&str] = &[
    "text",
    "info",
    "schema",
    "run",
    "rows",
    "cell",
    "explain",
    "export",
    "open_file",
];

/// The database and what is kept of its results.
pub struct App {
    pub db: Db,
    pub results: Results,
}

impl App {
    pub fn new(db: Db) -> Self {
        Self {
            db,
            results: Results::new(),
        }
    }

    /// Answers the page's call `method`; `stop` says whether the page gave it up.
    pub fn call(
        &self,
        method: &str,
        params: &Value,
        stop: &(dyn Fn() -> bool + Sync),
    ) -> Result<Value, ViewError> {
        match method {
            "info" => {
                let info = self.db.info().map_err(refused)?;
                Ok(json!({
                    "engine": info.engine,
                    "version": info.version,
                    "database": info.database,
                    "place": info.place,
                    "read_only": info.read_only,
                }))
            }
            "schema" => {
                let tables = self.db.tables().map_err(refused)?;
                Ok(json!({ "tables": tables.iter().map(table_json).collect::<Vec<_>>() }))
            }
            "run" => {
                let sql = statement(params)?;
                Ok(match self.db.run(sql, stop) {
                    Ok(outcome) => {
                        let first = rows_json(
                            &outcome.rows[..outcome.rows.len().min(FIRST_ROWS)],
                            ROW_BYTES,
                        );
                        let total = outcome.rows.len();
                        let columns = columns_json(&outcome.columns);
                        let result = (!outcome.columns.is_empty())
                            .then(|| self.results.keep(outcome.columns, outcome.rows));
                        json!({
                            "result": result,
                            "columns": columns,
                            "rows": first,
                            "total": total,
                            "cut": outcome.cut,
                            "tag": outcome.tag,
                            "ms": outcome.elapsed.as_secs_f64() * 1000.0,
                        })
                    }
                    Err(failure) => json!({ "error": failure.to_json() }),
                })
            }
            "rows" => {
                let id = number(params, "result")?;
                let from = usize::try_from(number(params, "from")?).unwrap_or(usize::MAX);
                let count = usize::try_from(number(params, "count")?)
                    .unwrap_or(MOST_ROWS)
                    .min(MOST_ROWS);
                self.results
                    .with(id, |kept| {
                        let to = from.saturating_add(count).min(kept.rows.len());
                        let from = from.min(to);
                        json!({ "from": from, "rows": rows_json(&kept.rows[from..to], ROW_BYTES) })
                    })
                    .ok_or_else(gone)
            }
            "cell" => {
                let id = number(params, "result")?;
                let row = usize::try_from(number(params, "row")?).unwrap_or(usize::MAX);
                let column = usize::try_from(number(params, "column")?).unwrap_or(usize::MAX);
                self.results
                    .with(id, |kept| {
                        let value = kept
                            .rows
                            .get(row)
                            .and_then(|values| values.get(column))
                            .cloned()
                            .flatten();
                        let column = kept.columns.get(column);
                        json!({
                            "value": value.map(|text| db::cut(text, VALUE_CAP)),
                            "name": column.map(|column| column.name.clone()),
                            "type": column.map(|column| column.kind.clone()),
                        })
                    })
                    .ok_or_else(gone)
            }
            "explain" => {
                let sql = statement(params)?;
                let analyze = params["analyze"].as_bool().unwrap_or(false);
                Ok(match self.db.explain(sql, analyze, stop) {
                    Ok(plan) => json!({ "plan": plan.to_json() }),
                    Err(failure) => json!({ "error": failure.to_json() }),
                })
            }
            "text" => {
                // The rows, whole, as tab-separated text for the pasteboard (which takes 64 KiB).
                let id = number(params, "result")?;
                self.results
                    .with(id, |kept| {
                        let (text, rows) = db::tsv(kept, COPY_BYTES);
                        json!({ "text": text, "rows": rows, "of": kept.rows.len() })
                    })
                    .ok_or_else(gone)
            }
            "export" => {
                let id = number(params, "result")?;
                let text = self.results.with(id, db::csv).ok_or_else(gone)?;
                let stamp = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map_or(0, |since| since.as_secs());
                let path = std::env::current_dir()
                    .map_err(io)?
                    .join(format!("sqlpen-{stamp}.csv"));
                std::fs::write(&path, text).map_err(io)?;
                Ok(json!({ "path": path.display().to_string() }))
            }
            "open_file" => {
                // A file the person dropped on the page: SQL text, read whole.
                let path = params["path"]
                    .as_str()
                    .ok_or_else(|| ViewError::new("bad-params"))?;
                let path = Path::new(path);
                let is_sql = path
                    .extension()
                    .and_then(|extension| extension.to_str())
                    .is_some_and(|extension| extension.eq_ignore_ascii_case("sql"));
                if !is_sql {
                    return Err(ViewError::with_message(
                        "not-sql",
                        "only a .sql file is read",
                    ));
                }
                if std::fs::metadata(path).map_err(io)?.len() > FILE_CAP {
                    return Err(ViewError::with_message(
                        "too-large",
                        "the file is larger than 512 KiB",
                    ));
                }
                let text = std::fs::read_to_string(path).map_err(io)?;
                Ok(
                    json!({ "text": text, "name": path.file_name().map(|name| name.to_string_lossy().into_owned()) }),
                )
            }
            _ => Err(ViewError::new("no-method")),
        }
    }
}

fn table_json(table: &db::Table) -> Value {
    json!({
        "schema": table.schema,
        "name": table.name,
        "kind": table.kind,
        "rows": table.rows,
        "visible": table.visible,
        "columns": table.columns.iter().map(|column| json!({
            "name": column.name,
            "type": column.kind,
            "key": column.key,
            "nullable": column.nullable,
        })).collect::<Vec<_>>(),
    })
}

fn statement(params: &Value) -> Result<&str, ViewError> {
    params["sql"]
        .as_str()
        .filter(|sql| !sql.trim().is_empty())
        .ok_or_else(|| ViewError::with_message("bad-params", "no statement"))
}

fn number(params: &Value, name: &str) -> Result<u64, ViewError> {
    params[name]
        .as_u64()
        .ok_or_else(|| ViewError::with_message("bad-params", format!("no {name}")))
}

fn refused(failure: Failure) -> ViewError {
    ViewError::with_message("database", failure.message)
}

fn io(why: std::io::Error) -> ViewError {
    ViewError::with_message("io", why.to_string())
}

fn gone() -> ViewError {
    ViewError::with_message(
        "gone",
        "that result is no longer kept: run the statement again",
    )
}
