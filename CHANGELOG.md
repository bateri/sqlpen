# Changelog

Every change a user of sqlpen would notice, newest first. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[semantic versioning](https://semver.org/): while sqlpen is `0.x`, a minor release may change what
the previous one did.

## [Unreleased]

### Added

- A SQL client in the terminal pane for PostgreSQL (`postgres://…`, or `$DATABASE_URL`) and SQLite
  (a file, or `--demo`: a small shop in memory), drawn by a terminal that hosts pencere views.
- The tables, views and columns of the database at the left, with how many rows each has; a double
  click shows a table's rows.
- An editor that knows SQL: Tab completes tables (schema-qualified where PostgreSQL needs it),
  columns and keywords; ⌘Enter runs the statement under the caret, or what is selected; a mistake
  is marked where the database points, with a hint where a table is in another schema.
- The rows in a grid that reads them as it scrolls, both ways, with its header held to its columns;
  columns sized by their contents and by a drag or a double click on their edge; a double click on
  a cell shows its whole value, JSON set out and coloured.
- How a statement would run (⌘E, ⇧⌘E to run it too), as a tree: each step's share of the time or
  the cost, and a step that reads a whole table of many rows marked.
- The rows as CSV, and copied as TSV; a `.sql` file dropped on the pane opens in the editor.
- Read only unless `--write`: each statement runs in a read-only transaction that is rolled back,
  with a timeout (`--timeout`, 30 seconds) and a stop (⌘.). The connection string is never shown.
