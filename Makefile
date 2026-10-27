# sqlpen's gate: formatting, lints, the program's tests, the page's and the installer's; `make dev`;
# and the steps of a release, in the order and for the reasons RELEASING.md gives.
.PHONY: check fmt lint test test-page test-tools shots pencere dev dist sums release-prepare rehearse

# pencere is pinned in one place, Cargo.lock (Cargo.toml names the commit): the crates the program
# is built on, and the page's tests, run in pencere's own interpreter, are of it. `make dev` runs
# sqlpen under the `pencere` command of the same pencere, built from it in .cache/pencere: nothing
# looks at a pencere beside this directory or on PATH. To work against a checkout you are changing,
# say so; one that is not at Cargo.lock's ref is said to be so, and used:
#
#   make dev PENCERE_SRC=../pencere
PENCERE_REF = $(shell node tools/release.mjs pencere-ref)
PENCERE_CACHE = .cache/pencere
PENCERE_SRC ?= $(PENCERE_CACHE)
PENCERE ?= $(PENCERE_SRC)/target/release/pencere
PENCERE_GIT = https://github.com/bateri/pencere

fmt:
	cargo fmt

lint:
	cargo fmt -- --check
	cargo clippy --locked --all-targets -- -D warnings

# The program's tests; the PostgreSQL ones run against the server SQLPEN_TEST_PG names (README).
test:
	cargo test --locked

# The page, in pencere's interpreter with pencere's editors: the interpreter is compiled, so it takes
# a few seconds. The pictures of the page (`shots`) are not part of it: they are for a person to look
# at, drawn in the system's fonts of a Mac.
test-page:
	cargo test --locked -- --ignored --skip shots

# The installer (install.sh), run against a stand-in for GitHub.
test-tools:
	node --test test/install.test.mjs

check: lint test test-page test-tools

# shots draws the page as the kit lays it out into target/shots/*.png (macOS: its fonts).
shots:
	cargo test --locked shots -- --ignored

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

# dist makes the program for one target (TARGET, a Rust target triple) into dist/release, as
# sqlpen-<version>-<target>. The release workflow runs it on a machine of each of the three targets
# sqlpen ships (Apple silicon Macs and both Linux architectures, the Linux ones linked statically with
# musl; bateri, the terminal that shows the page, runs on Apple silicon only), then `make sums` where
# the three files are together.
TARGETS = aarch64-apple-darwin aarch64-unknown-linux-musl x86_64-unknown-linux-musl
PACKAGE_VERSION = $(shell node tools/release.mjs version)

dist:
	@test -n "$(TARGET)" || { echo "usage: make dist TARGET=<one of: $(TARGETS)>"; exit 2; }
	cargo build --locked --release --target $(TARGET)
	mkdir -p dist/release
	cp target/$(TARGET)/release/sqlpen dist/release/sqlpen-$(PACKAGE_VERSION)-$(TARGET)

# sums writes the SHA256SUMS of the three files of dist/release, and checks them.
sums:
	cd dist/release && { sha256sum sqlpen-* 2>/dev/null || shasum -a 256 sqlpen-*; } > SHA256SUMS
	@cat dist/release/SHA256SUMS
	node tools/release.mjs dist dist/release

# release-prepare sets the version and dates the changelog's Unreleased section.
release-prepare:
	@test -n "$(VERSION)" || { echo "usage: make release-prepare VERSION=<x.y.z>"; exit 2; }
	node tools/release.mjs prepare $(VERSION)

# rehearse runs the checks of a release of the prepared version, on any branch. It changes nothing:
# a release is the commit of release-prepare pushed to main, which the release workflow tags, builds
# and drafts once the gate is green, and publishes when a maintainer approves (RELEASING.md).
rehearse:
	node tools/release.mjs rehearse
