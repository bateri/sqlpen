# sqlpen's gate: formatting, lints, the program's tests and the page's.
.PHONY: check fmt lint test test-page

fmt:
	cargo fmt

lint:
	cargo fmt -- --check
	cargo clippy --all-targets -- -D warnings

# The program's tests; the PostgreSQL ones run against the server SQLPEN_TEST_PG names (README).
test:
	cargo test

# The page, in pencere's interpreter with pencere's editors: the interpreter is compiled, so it takes
# a few seconds.
test-page:
	cargo test -- --ignored

check: lint test test-page
