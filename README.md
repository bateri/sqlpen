# sqlpen

A SQL client in the terminal pane, for PostgreSQL and SQLite: the tables of the database at the
left, an editor that knows SQL above, and what a statement gave below — its rows in a grid, how it
runs, or what was wrong with it, marked where the database pointed. With the keyboard or the mouse,
in the colours and the font of your terminal, on your machine or on a server over plain `ssh`.

sqlpen is a [pencere](https://github.com/bateri/pencere) program. Run it in a terminal that hosts
pencere views ([bateri](https://github.com/bateri/bateri)) and the pane becomes the interface, the
way `vim` takes the screen and gives it back; quit and the shell is where it was. Run it anywhere
else and it says what it is connected to and the tables there are.

```sh
sqlpen --demo                                   # a small shop in SQLite, in memory
sqlpen app.db                                   # a SQLite file
sqlpen postgres://reader@db.example.com/shop    # a PostgreSQL database
sqlpen                                          # the one $DATABASE_URL names
```

## What it does

**The editor is the terminal's own** (pencere's editor): several carets, undo, the input method of
your keyboard, find, folding. sqlpen makes SQL of it:

- keywords, strings, numbers, comments and parameters in the colours of the terminal's theme;
- completions by the caret, opening as you type a word: the database's own tables after `from` and
  `join` (written with their schema where it is not on PostgreSQL's `search_path`, so that what is
  put in runs: `shop.customers`), a schema's tables after `shop.`, the columns of a table after its
  name or alias and a dot, then keywords and functions. **Tab** puts the chosen one in, or, where
  the list is closed, completes the word the caret is at (the word itself if only one fits) and
  indents anywhere else; ↑ ↓ choose, Enter puts it in too, Esc closes. Nothing is offered inside a
  string or a comment;
- each statement of more than one line folds;
- ⌘ Enter runs the statement the caret is in, or what is selected; ⌘E shows how it would run, ⇧⌘E
  (PostgreSQL) runs it and shows how it went; ⌘. stops it;
- a mistake is underlined where the database points, with its detail and hint below — a table
  named without its schema says which schema it is in;
- drop a `.sql` file on the page to open it.

**The grid** has a column of row numbers, NULL that is not an empty string, numbers to the right,
booleans and JSON in their own colours. Rows are read from the program as they come into view, so a
result of ten thousand rows scrolls as one of ten. Drag a column's edge to widen it, double-click it to fit the column to what is in it; click its name
to sort (a result of up to a thousand rows); a cell is chosen with the pointer or the arrows, ⌘C
copies it, and a double click or ↩ opens its whole value — JSON set out and coloured. Copy puts the
rows, whole, as tab-separated text on the pasteboard (as many as it takes, 60 KiB); CSV saves the result in the current directory.

**The plan** is a tree of the steps a statement runs in, each with a bar of its share of the time
(run with ANALYZE) or of the planner's cost, the rows it was thought to give and gave, its
conditions; a step that reads a whole large table is marked.

**The tables** at the left are grouped by schema where there are several, with how many rows each
has; a click opens one to its columns (keys marked), a double click shows its rows, and a click on
a column writes its name where the caret is.

## Safety

A database is opened **read only** unless sqlpen is run with `--write`. For PostgreSQL every
statement runs in a `READ ONLY` transaction that is rolled back after, so it is the server that
refuses a write; for SQLite the file is opened for reading and the connection is `query_only`.
With `--write`, a write runs as it was written, outside any transaction of sqlpen's.

A statement may run for 30 seconds before it is stopped (`--timeout <seconds>` lets it run longer). A result keeps at most 10 000 rows (it
says when it was cut) and the grid shows at most 160 characters of a value; the whole value opens
on its own. A query against PostgreSQL is read through a cursor, so a `select *` of a large table
costs the rows kept, not the table.

The connection string is never shown: the header says `user@host:port`, never a password.

A connection the server closed (it restarted, a proxy let go of it) is opened again for the next
statement.

Known limits: with `--write`, a statement that is not a query (an `INSERT … RETURNING`) is run as
it is and all it returns is read before the first 10 000 are kept; the list of tables is one message,
so a database of many thousands of tables may not show them all; a dropped `.sql` file is opened up
to 512 KiB.

## Building

```sh
cargo build --release      # target/release/sqlpen, the page carried in it
make check                 # formatting, lints and the tests (the page's included)
```

The page (`src/view/`, Lua) is run by the tests in pencere's own interpreter, with pencere's
editors, its calls answered by the program over the demo's database (`make test-page`). The
PostgreSQL tests run against a server when `SQLPEN_TEST_PG` names one:

```sh
docker run -d --name sqlpen-pg -e POSTGRES_PASSWORD=sqlpen -e POSTGRES_DB=shop \
  -p 127.0.0.1:55432:5432 postgres:17 -c shared_preload_libraries=pg_stat_statements
docker exec -i sqlpen-pg psql -q -U postgres -d shop < demo/postgres.sql
SQLPEN_TEST_PG=postgres://reader:reader@127.0.0.1:55432/shop make check
```

In a terminal that hosts pencere, `make dev` runs sqlpen in the pane on the database
`$DATABASE_URL` names, and shows the page again when a file of `src/view/` changes. Its `pencere`
command is built from the pencere `Cargo.lock` pins, fetched into `.cache/pencere`; to run against a
pencere checkout you are changing, `make dev PENCERE_SRC=../pencere`.

## License

GPL-3.0-or-later. The icons are [Lucide](https://lucide.dev)'s (ISC, `src/assets/icons/LICENSE`).
The lexer of `src/view/lib/sql.lua` began as the one of pencere's `examples/editor-lua`
(Apache-2.0).
