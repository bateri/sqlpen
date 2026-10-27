//! sqlpen: a SQL client in the terminal pane, for PostgreSQL and SQLite.
//!
//! The program is the database's side: it connects, runs what the page asks, keeps the rows of a
//! result and hands them to the page a window at a time. The page (`src/view/`) is the interface,
//! drawn by the terminal, with the terminal's editor for the SQL. Run anywhere a terminal shows no
//! views, it says what it is connected to and the tables there are.

mod calls;
mod db;
#[cfg(test)]
mod page_tests;
#[cfg(test)]
mod shot;

use std::path::Path;
use std::process::ExitCode;
use std::sync::Arc;

use pencere::Options;

use calls::{App, METHODS};
use db::Db;

const USAGE: &str = "\
sqlpen: a SQL client in the terminal pane, for PostgreSQL and SQLite

usage:
  sqlpen [--write] postgres://user@host/db    a PostgreSQL database
  sqlpen [--write] file.db                    a SQLite database
  sqlpen [--write]                            the database $DATABASE_URL names
  sqlpen --demo                               a small shop in SQLite, in memory

A database is opened read only: --write lets statements change it. A statement may run
30 seconds: --timeout <seconds> lets it run longer.";

enum Target {
    Postgres(String),
    Sqlite(String),
    Demo,
}

fn main() -> ExitCode {
    let mut write = false;
    let mut target = None;
    let mut arguments = std::env::args().skip(1);
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--write" => write = true,
            "--timeout" => {
                let seconds = arguments
                    .next()
                    .and_then(|seconds| seconds.parse::<u64>().ok());
                match seconds.filter(|seconds| *seconds > 0) {
                    Some(seconds) => db::set_timeout(std::time::Duration::from_secs(seconds)),
                    None => {
                        eprintln!("sqlpen: --timeout takes a number of seconds\n\n{USAGE}");
                        return ExitCode::from(64);
                    }
                }
            }
            "--demo" => target = Some(Target::Demo),
            "-h" | "--help" => {
                println!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            "-V" | "--version" => {
                println!("sqlpen {}", env!("CARGO_PKG_VERSION"));
                return ExitCode::SUCCESS;
            }
            other if other.starts_with('-') => {
                eprintln!("sqlpen: no option {other}\n\n{USAGE}");
                return ExitCode::from(64);
            }
            other => target = Some(target_of(other)),
        }
    }
    let target = match target.or_else(|| {
        std::env::var("DATABASE_URL")
            .ok()
            .map(|url| target_of(&url))
    }) {
        Some(target) => target,
        None => {
            eprintln!("sqlpen: which database? Name one, or set DATABASE_URL.\n\n{USAGE}");
            return ExitCode::from(64);
        }
    };
    let opened = match &target {
        Target::Postgres(address) => {
            db::postgres::Postgres::connect(address, write).map(|db| Db::Postgres(Box::new(db)))
        }
        Target::Sqlite(path) => db::sqlite::Sqlite::open(Path::new(path), write).map(Db::Sqlite),
        Target::Demo => db::sqlite::Sqlite::demo(write).map(Db::Sqlite),
    };
    let app = match opened {
        Ok(db) => Arc::new(App::new(db)),
        Err(failure) => {
            eprintln!("sqlpen: {}", failure.message);
            return ExitCode::from(1);
        }
    };
    match serve(app) {
        Ok(status) => ExitCode::from(status),
        Err(why) => {
            eprintln!("sqlpen: {why}");
            ExitCode::from(1)
        }
    }
}

/// A connection string is PostgreSQL's; anything else is the path of a SQLite file.
fn target_of(argument: &str) -> Target {
    let postgres = argument.starts_with("postgres://")
        || argument.starts_with("postgresql://")
        || (argument.contains('=') && (argument.contains("host=") || argument.contains("dbname=")));
    if postgres {
        Target::Postgres(argument.to_owned())
    } else {
        Target::Sqlite(argument.to_owned())
    }
}

fn serve(app: Arc<App>) -> Result<u8, pencere::Error> {
    let mut options = Options::new()
        .app(pencere::app!())
        .program("sqlpen")
        .title("sqlpen");
    for method in METHODS {
        let app = Arc::clone(&app);
        options = options.call(*method, move |params, call| {
            app.call(method, &params, &|| call.is_cancelled())
        });
    }
    let options = options.fallback(move |_why| describe(&app.db));
    let outcome = pencere::serve(options)?;
    Ok(outcome.shell_status())
}

/// Where a terminal shows no views: what the database is and the tables in it.
fn describe(db: &Db) {
    match db.info() {
        Ok(info) => println!(
            "{} · {} · {}{}",
            info.version,
            info.database,
            info.place,
            if info.read_only { " · read only" } else { "" }
        ),
        Err(failure) => println!("sqlpen: {}", failure.message),
    }
    if let Ok(tables) = db.tables() {
        for table in tables {
            let rows = table
                .rows
                .map_or_else(String::new, |rows| format!("  {rows} rows"));
            println!("  {}.{}  {}{rows}", table.schema, table.name, table.kind);
        }
    }
    println!("sqlpen shows its interface in a terminal that hosts pencere views.");
}
