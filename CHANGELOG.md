# Changelog

Every change a user of sqlpen would notice, newest first. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[semantic versioning](https://semver.org/): while sqlpen is `0.x`, a minor release may change what
the previous one did.

## [Unreleased]

### Fixed

- A screen reader, and an agent that reads the pane, are told which completion is chosen, which row
  holds the chosen cell of the results and which cell it is, and what the divider between the editor
  and the results is for, and the card of an open value and the click that closes it have a name,
  where the click was read as one button with all the words of the card. They were told by fill alone,
  or not at all.
  The card of an open value is read as a dialog, with the page behind it left out of what is read, and the
  dimmed part around it is not read. The lines that resize a column are sliders with the column's name,
  where they were unnamed buttons. A pencere too old for this shows a screen that says to update bateri,
  instead of a page that does not run.

## [0.2.0] - 2026-11-09

### Added

- **Releases carry a signed `app.json`.** A terminal that follows sqlpen (bateri, from its list of
  apps) reads it to find the newest file it can open and to know the file is the one the maintainer
  released. `make sums` writes it and its signature beside `SHA256SUMS`, and the release checks
  refuse a release without them.

### Changed

- Building from source now needs Rust 1.99 or later.

## [0.1.0] - 2026-11-03

### Fixed

- Typing a letter such as `ş`, `ğ` or `ü` while the keyboard is off the editor gives it back to the
  editor, as typing `a` does.

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
