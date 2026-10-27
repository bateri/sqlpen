//! The databases sqlpen speaks to, behind one shape the page reads: what the database is, what is in
//! it, what a statement gave and how it would be run.
//!
//! Every value reaches the page as text (or as nothing, for NULL): a grid shows words, and turning a
//! value into words once, here, is what lets both engines look alike to the page. A result is kept
//! here, capped, and the page reads it a window at a time ([`Results`]); no message to the page ever
//! carries more than a window.

pub mod postgres;
pub mod sqlite;

use std::collections::VecDeque;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

/// The rows a statement may give that are kept: past them the result says it was cut.
pub const ROW_CAP: usize = 10_000;
/// The characters of a value that go to the grid (it shows a few dozen); the whole of it is asked
/// for on its own.
pub const CELL_CAP: usize = 160;
/// The characters of a value a page may ask for whole (`cell`).
pub const VALUE_CAP: usize = 256 * 1024;
/// How long a statement may run before it is stopped, unless the person says otherwise
/// (`--timeout`).
pub const STATEMENT_TIMEOUT: Duration = Duration::from_secs(30);
static TIMEOUT: std::sync::OnceLock<Duration> = std::sync::OnceLock::new();

/// Sets how long a statement may run, once, before any runs.
pub fn set_timeout(timeout: Duration) {
    let _ = TIMEOUT.set(timeout);
}

/// How long a statement may run.
pub fn timeout() -> Duration {
    TIMEOUT.get().copied().unwrap_or(STATEMENT_TIMEOUT)
}

/// What a statement stopped for running too long says.
pub fn too_long() -> String {
    format!(
        "It ran longer than {} s and was stopped: sqlpen --timeout <seconds> lets a statement run longer",
        timeout().as_secs()
    )
}
/// The results kept for the page to read on: the newest few.
const KEPT: usize = 8;

/// One column of a result.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Column {
    pub name: String,
    /// The type as the database names it (`int8`, `text`, `REAL`…), or empty where it says none.
    pub kind: String,
    /// Numbers: the grid sets them to the right.
    pub numeric: bool,
}

/// What a statement did.
#[derive(Debug, Default, PartialEq)]
pub struct Outcome {
    pub columns: Vec<Column>,
    pub rows: Vec<Vec<Option<String>>>,
    /// More rows came than are kept.
    pub cut: bool,
    /// What it did, as the database says it: `SELECT 23`, `UPDATE 3`, `CREATE TABLE`.
    pub tag: String,
    pub elapsed: Duration,
}

/// Why a statement failed, as the database said it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Failure {
    pub message: String,
    pub detail: Option<String>,
    pub hint: Option<String>,
    /// The character of the statement the database points at, from 0.
    pub position: Option<usize>,
    /// The database's own code for it (SQLSTATE for PostgreSQL).
    pub code: Option<String>,
}

impl Failure {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            ..Self::default()
        }
    }

    pub fn to_json(&self) -> Value {
        json!({
            "message": self.message,
            "detail": self.detail,
            "hint": self.hint,
            "position": self.position,
            "code": self.code,
        })
    }
}

/// A table or a view, and its columns.
#[derive(Clone, Debug, PartialEq)]
pub struct Table {
    pub schema: String,
    pub name: String,
    /// `table` or `view`.
    pub kind: &'static str,
    /// How many rows it has, where that is known cheaply.
    pub rows: Option<i64>,
    pub columns: Vec<SchemaColumn>,
    /// Whether a statement finds it by its name alone (PostgreSQL's `search_path`): one that is not
    /// is written with its schema.
    pub visible: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SchemaColumn {
    pub name: String,
    pub kind: String,
    pub key: bool,
    pub nullable: bool,
}

/// One step of a plan, and the steps under it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Step {
    /// What it does: `Seq Scan on orders`, `SEARCH customers USING INTEGER PRIMARY KEY`.
    pub label: String,
    /// What else is said of it: its filter, its index condition.
    pub detail: Vec<String>,
    /// The planner's cost of it, all that is under it included (PostgreSQL).
    pub cost: Option<f64>,
    /// The rows the planner thinks it gives.
    pub rows: Option<f64>,
    /// With ANALYZE: how long it took, milliseconds, and the rows it gave.
    pub time: Option<f64>,
    pub actual_rows: Option<f64>,
    pub children: Vec<Step>,
}

impl Step {
    pub fn to_json(&self) -> Value {
        json!({
            "label": self.label,
            "detail": self.detail,
            "cost": self.cost,
            "rows": self.rows,
            "time": self.time,
            "actual_rows": self.actual_rows,
            "children": self.children.iter().map(Step::to_json).collect::<Vec<_>>(),
        })
    }
}

/// What the page is told of the database it is looking at.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Info {
    pub engine: &'static str,
    pub version: String,
    /// The database's name: PostgreSQL's database, SQLite's file name.
    pub database: String,
    /// Where it is, without any secret: `reader@127.0.0.1:55432`, a file's path.
    pub place: String,
    pub read_only: bool,
}

/// A database, either kind.
pub enum Db {
    Postgres(Box<postgres::Postgres>),
    Sqlite(sqlite::Sqlite),
}

impl Db {
    pub fn info(&self) -> Result<Info, Failure> {
        match self {
            Self::Postgres(db) => db.info(),
            Self::Sqlite(db) => db.info(),
        }
    }

    pub fn tables(&self) -> Result<Vec<Table>, Failure> {
        match self {
            Self::Postgres(db) => db.tables(),
            Self::Sqlite(db) => db.tables(),
        }
    }

    /// Runs one statement, stopping it if `stop` says so before it is done.
    pub fn run(&self, sql: &str, stop: &(dyn Fn() -> bool + Sync)) -> Result<Outcome, Failure> {
        match self {
            Self::Postgres(db) => db.run(sql, stop),
            Self::Sqlite(db) => db.run(sql, stop),
        }
    }

    /// How the statement would be run; with `analyze`, run it and say how it went.
    pub fn explain(
        &self,
        sql: &str,
        analyze: bool,
        stop: &(dyn Fn() -> bool + Sync),
    ) -> Result<Step, Failure> {
        match self {
            Self::Postgres(db) => db.explain(sql, analyze, stop),
            Self::Sqlite(db) => db.explain(sql, stop),
        }
    }
}

/// Waits on another thread while `work` runs, and calls `cancel` once when `stop` says to, or when
/// the statement has run longer than [`timeout`]. What `work` gives back, and whether it was
/// stopped for running too long.
pub fn watched<T>(
    stop: &(dyn Fn() -> bool + Sync),
    cancel: impl Fn() + Sync,
    work: impl FnOnce() -> T,
) -> (T, bool) {
    let done = std::sync::atomic::AtomicBool::new(false);
    let timed_out = std::sync::atomic::AtomicBool::new(false);
    let started = Instant::now();
    let result = std::thread::scope(|scope| {
        scope.spawn(|| {
            while !done.load(Ordering::SeqCst) {
                std::thread::sleep(Duration::from_millis(25));
                if done.load(Ordering::SeqCst) {
                    break;
                }
                let late = started.elapsed() > timeout();
                if late || stop() {
                    timed_out.store(late, Ordering::SeqCst);
                    cancel();
                    break;
                }
            }
        });
        let result = work();
        done.store(true, Ordering::SeqCst);
        result
    });
    (result, timed_out.load(Ordering::SeqCst))
}

/// A value cut to what the grid shows.
pub fn for_grid(value: Option<String>) -> Option<String> {
    value.map(|text| cut(text, CELL_CAP))
}

/// `text`, at most `most` characters of it, "…" where it was cut.
pub fn cut(text: String, most: usize) -> String {
    match text.char_indices().nth(most) {
        Some((at, _)) => {
            let mut short = text[..at].to_owned();
            short.push('…');
            short
        }
        None => text,
    }
}

/// The verb a statement starts with, as the tag of what it did says it (`SELECT`, `UPDATE`…).
pub fn verb_of(sql: &str) -> String {
    let mut rest = sql.trim_start();
    // Comments before the statement are not its verb.
    loop {
        if let Some(after) = rest.strip_prefix("--") {
            rest = after
                .split_once('\n')
                .map_or("", |(_, next)| next)
                .trim_start();
        } else if let Some(after) = rest.strip_prefix("/*") {
            rest = after
                .split_once("*/")
                .map_or("", |(_, next)| next)
                .trim_start();
        } else {
            break;
        }
    }
    rest.split(|c: char| !c.is_alphanumeric())
        .next()
        .unwrap_or("")
        .to_uppercase()
}

/// The results the page reads on, by the number each was given.
pub struct Results {
    next: AtomicU64,
    kept: Mutex<VecDeque<(u64, Kept)>>,
}

/// A result as it is kept: its columns and every row, whole.
pub struct Kept {
    pub columns: Vec<Column>,
    pub rows: Vec<Vec<Option<String>>>,
}

impl Default for Results {
    fn default() -> Self {
        Self::new()
    }
}

impl Results {
    pub fn new() -> Self {
        Self {
            next: AtomicU64::new(1),
            kept: Mutex::new(VecDeque::new()),
        }
    }

    /// Keeps a result; its number.
    pub fn keep(&self, columns: Vec<Column>, rows: Vec<Vec<Option<String>>>) -> u64 {
        let id = self.next.fetch_add(1, Ordering::SeqCst);
        let mut kept = self
            .kept
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        kept.push_back((id, Kept { columns, rows }));
        while kept.len() > KEPT {
            kept.pop_front();
        }
        id
    }

    /// What `read` makes of the result numbered `id`, if it is still kept.
    pub fn with<T>(&self, id: u64, read: impl FnOnce(&Kept) -> T) -> Option<T> {
        let kept = self
            .kept
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        kept.iter()
            .find(|(at, _)| *at == id)
            .map(|(_, kept)| read(kept))
    }
}

/// A result's rows as a page reads them, values cut for the grid: as many of `rows` as there are
/// until they come to `budget` bytes of JSON, one at least. The page reads what it is sent at once,
/// in a call of its own that has its time, so a window of a wide table is fewer rows, not a longer
/// message.
pub fn rows_json(rows: &[Vec<Option<String>>], budget: usize) -> Value {
    let mut out = Vec::new();
    let mut size = 0;
    for row in rows {
        let row = Value::Array(
            row.iter()
                .map(|value| for_grid(value.clone()).map_or(Value::Null, Value::String))
                .collect(),
        );
        size += row.to_string().len() + 1;
        if size > budget && !out.is_empty() {
            break;
        }
        out.push(row);
    }
    Value::Array(out)
}

pub fn columns_json(columns: &[Column]) -> Value {
    Value::Array(
        columns
            .iter()
            .map(|column| json!({ "name": column.name, "type": column.kind, "numeric": column.numeric }))
            .collect(),
    )
}

/// A result as tab-separated text, a header of the column names and the rows whole (a tab or a line
/// break in a value is a space), as many rows as fit in `most` bytes: the text and how many rows.
pub fn tsv(kept: &Kept, most: usize) -> (String, usize) {
    let flat = |text: &str| text.replace(['\t', '\n', '\r'], " ");
    let mut out = kept
        .columns
        .iter()
        .map(|column| flat(&column.name))
        .collect::<Vec<_>>()
        .join("\t");
    let mut rows = 0;
    for row in &kept.rows {
        let line = row
            .iter()
            .map(|value| value.as_deref().map(flat).unwrap_or_default())
            .collect::<Vec<_>>()
            .join("\t");
        if out.len() + 1 + line.len() > most {
            break;
        }
        out.push('\n');
        out.push_str(&line);
        rows += 1;
    }
    (out, rows)
}

/// A result as comma-separated values (RFC 4180): a header of the column names, then the rows; NULL
/// is nothing between the commas.
pub fn csv(kept: &Kept) -> String {
    fn field(out: &mut String, text: &str) {
        if text.contains([',', '"', '\n', '\r']) {
            out.push('"');
            out.push_str(&text.replace('"', "\"\""));
            out.push('"');
        } else {
            out.push_str(text);
        }
    }
    let mut out = String::new();
    for (index, column) in kept.columns.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        field(&mut out, &column.name);
    }
    out.push_str("\r\n");
    for row in &kept.rows {
        for (index, value) in row.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            if let Some(value) = value {
                field(&mut out, value);
            }
        }
        out.push_str("\r\n");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_verb_of_a_statement_skips_its_comments() {
        assert_eq!(verb_of("  -- why\n/* how */ select 1"), "SELECT");
        assert_eq!(verb_of("update t set a = 1"), "UPDATE");
        assert_eq!(verb_of(""), "");
    }

    #[test]
    fn a_long_value_is_cut_for_the_grid_and_a_short_one_is_not() {
        assert_eq!(cut("şöyle".into(), 3), "şöy…");
        assert_eq!(cut("abc".into(), 3), "abc");
    }

    #[test]
    fn csv_quotes_what_needs_it_and_leaves_null_empty() {
        let kept = Kept {
            columns: vec![
                Column {
                    name: "a".into(),
                    kind: String::new(),
                    numeric: false,
                },
                Column {
                    name: "b,c".into(),
                    kind: String::new(),
                    numeric: false,
                },
            ],
            rows: vec![vec![Some("say \"hi\"".into()), None]],
        };
        assert_eq!(csv(&kept), "a,\"b,c\"\r\n\"say \"\"hi\"\"\",\r\n");
    }

    #[test]
    fn rows_for_the_page_stop_at_their_budget_and_one_always_goes() {
        let wide = vec![vec![Some("x".repeat(1000)); 20]; 50];
        let sent = rows_json(&wide, 32 * 1024);
        let count = sent.as_array().unwrap().len();
        assert!((1..50).contains(&count), "{count}");
        assert!(sent.to_string().len() < 40 * 1024);
        assert_eq!(rows_json(&wide[..1], 10).as_array().unwrap().len(), 1);
    }

    #[test]
    fn tab_separated_text_keeps_values_whole_and_stops_at_its_size() {
        let kept = Kept {
            columns: vec![Column {
                name: "a".into(),
                kind: String::new(),
                numeric: false,
            }],
            rows: vec![
                vec![Some("x".repeat(300))],
                vec![None],
                vec![Some("tab\there".into())],
            ],
        };
        let (text, rows) = tsv(&kept, 1024);
        assert_eq!(rows, 3);
        assert!(text.contains(&"x".repeat(300)));
        assert!(text.ends_with("tab here"));
        assert_eq!(tsv(&kept, 100).1, 0);
    }

    #[test]
    fn only_the_newest_results_are_kept() {
        let results = Results::new();
        let first = results.keep(Vec::new(), Vec::new());
        for _ in 0..KEPT {
            results.keep(Vec::new(), Vec::new());
        }
        assert!(results.with(first, |_| ()).is_none());
    }
}
