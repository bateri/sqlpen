# sqlpen's gate: formatting, lints, the program's tests and the page's; and `make dev`.
.PHONY: check fmt lint test test-page pencere dev

# pencere is pinned in one place, Cargo.lock (Cargo.toml names the commit): the crates the program
# is built on, and the page's tests, run in pencere's own interpreter, are of it. `make dev` runs
# sqlpen under the `pencere` command of the same pencere, built from it in .cache/pencere: nothing
# looks at a pencere beside this directory or on PATH. To work against a checkout you are changing,
# say so; one that is not at Cargo.lock's ref is said to be so, and used:
#
#   make dev PENCERE_SRC=../pencere
PENCERE_REF = $(shell sh tools/pencere-ref)
PENCERE_CACHE = .cache/pencere
PENCERE_SRC ?= $(PENCERE_CACHE)
PENCERE ?= $(PENCERE_SRC)/target/release/pencere
PENCERE_GIT = https://github.com/bateri/pencere

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

# pencere makes PENCERE_SRC ready: fetched at Cargo.lock's ref when it is the cache (one checkout,
# moved to another ref when Cargo.lock moves, so that cargo builds again only what changed), and its
# command built there.
pencere:
	@command -v cargo >/dev/null || { echo "pencere: cargo is not installed: pencere is built from its source (https://rustup.rs)"; exit 1; }
	@ref="$(PENCERE_REF)"; test -n "$$ref" || exit 1; \
	if [ "$(PENCERE_SRC)" = "$(PENCERE_CACHE)" ]; then \
		if [ "$$(cat $(PENCERE_CACHE).ref 2>/dev/null)" != "$$ref" ]; then \
			echo "pencere: fetching $(PENCERE_GIT) at $$ref into $(PENCERE_CACHE)"; \
			{ test -d "$(PENCERE_CACHE)/.git" || git init -q "$(PENCERE_CACHE)"; } && \
			git -C "$(PENCERE_CACHE)" fetch -q --depth 1 "$(PENCERE_GIT)" "$$ref" && \
			git -C "$(PENCERE_CACHE)" checkout -q --detach --force FETCH_HEAD && \
			echo "$$ref" > "$(PENCERE_CACHE).ref" || exit 1; \
		fi; \
	else \
		head=$$(git -C "$(PENCERE_SRC)" rev-parse HEAD 2>/dev/null); \
		want=$$(git -C "$(PENCERE_SRC)" rev-parse -q --verify "$$ref^{commit}" 2>/dev/null); \
		[ -n "$$head" ] && [ "$$head" = "$$want" ] || \
			echo "pencere: $(PENCERE_SRC) is at $${head:-no commit}, not at $$ref (Cargo.lock) that sqlpen is built with"; \
	fi
	cd "$(PENCERE_SRC)" && cargo build --release -p pencere-cli

# dev runs sqlpen from its files in this pane, in a terminal that hosts pencere (bateri), on the
# database $$DATABASE_URL names; the page is shown again when a file of src/view/ changes, and the
# program built and run again when one of it does.
dev: pencere
	"$(PENCERE)" dev
