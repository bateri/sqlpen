# sqlpen's gate: formatting, lints, the program's tests, the page's and the installer's; `make dev`;
# and the steps of a release, in the order and for the reasons RELEASING.md gives.
.PHONY: fmt lint test test-page test-tools check shots pencere-src pencere fake-host pencere-ref dev dist sums release-prepare release publish

# pencere is pinned in one place, Cargo.lock (Cargo.toml names the commit): the crate the program is
# built on is of it, and so are the page's tests, run in pencere's own interpreter, and the `pencere`
# command `make dev` runs sqlpen under and `make sums` signs a release with, which are built from it
# in .cache/pencere. To work against a checkout you are changing, say so; one that is not at
# Cargo.lock's ref is said to be so, and used:
#
#   make dev PENCERE_SRC=../pencere
# The ref is the commit Cargo.lock takes it at, or the tag of the crates' release it takes.
PENCERE_REF = $(shell awk '/^name = "pencere"$$/ { getline v; getline s; gsub(/version = |"/, "", v); if (s ~ /^source = "registry/) print "crates-v" v; else { sub(/.*\#/, "", s); sub(/"$$/, "", s); print s } exit }' Cargo.lock)
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

# The installer (install.sh), run against a stand-in for GitHub, and the release checks
# (tools/release-files.mjs), against a directory of their own.
test-tools:
	node --test test/install.test.mjs test/release.test.mjs

check: lint test test-page test-tools

# shots draws the page as the kit lays it out into target/shots/*.png (macOS: its fonts).
shots:
	cargo test --locked shots -- --ignored

# pencere-src makes PENCERE_SRC ready: fetched at Cargo.lock's ref when it is the cache (one checkout,
# moved to another ref when Cargo.lock moves, so that cargo builds again only what changed).
pencere-src:
	@command -v cargo >/dev/null || { echo "pencere: cargo is not installed: pencere is built from its source (https://rustup.rs)"; exit 1; }
	@ref="$(PENCERE_REF)"; test -n "$$ref" || { echo "pencere: Cargo.lock takes no pencere"; exit 1; }; \
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

# pencere builds the `pencere` command in PENCERE_SRC.
pencere: pencere-src
	cd "$(PENCERE_SRC)" && cargo build --release -p pencere-cli

# fake-host builds the stand-in terminal in PENCERE_SRC.
fake-host: pencere-src
	cd "$(PENCERE_SRC)" && cargo build -p pencere-fake-host

# pencere-ref says which pencere Cargo.lock takes.
pencere-ref:
	@echo "$(PENCERE_REF)"

# dev runs sqlpen from its files in this pane, in a terminal that hosts pencere (bateri), on the
# database $$DATABASE_URL names; the page is shown again when a file of src/view/ changes, and the
# program built and run again when one of it does.
dev: pencere
	"$(PENCERE)" dev

# dist makes the program for one target (TARGET, a Rust target triple) into dist/release, as
# sqlpen-<version>-<target>: Apple silicon Macs and both Linux architectures, the Linux ones linked
# statically with musl (bateri, the terminal that shows the page, runs on Apple silicon only).
# Each is built on a machine of its own target, with that target added to the toolchain; `make sums`
# then names the three where they are together, and signs the app.json that says what they are.
TARGETS = aarch64-apple-darwin aarch64-unknown-linux-musl x86_64-unknown-linux-musl
PACKAGE_VERSION = $(shell sed -n 's/^version = "\(.*\)"$$/\1/p' Cargo.toml | head -n 1)

dist:
	@test -n "$(TARGET)" || { echo "usage: make dist TARGET=<one of: $(TARGETS)>"; exit 2; }
	cargo build --locked --release --target $(TARGET)
	mkdir -p dist/release
	cp target/$(TARGET)/release/sqlpen dist/release/sqlpen-$(PACKAGE_VERSION)-$(TARGET)

# sums writes the SHA256SUMS of the three files of dist/release, then the app.json that names them
# and its signature (`pencere dist`, which signs with the key `pencere key` made: ~/.config/pencere/
# signing.key, or the one PENCERE_SIGNING_KEY names). A terminal that follows sqlpen reads those
# two. What the program needs of its terminal in app.json comes from the program itself, the file
# of this machine's target, started once: sqlpen needs a database to start, so it is started as
# `sqlpen --demo` (--describe-args). DIST_FLAGS goes to `pencere dist`: --base, --previous.
#
# On release day PENCERE must be a pencere that has `dist` and is the one Cargo.lock takes
# (PENCERE_REF): `make pencere` builds it. A release made with another one has an app.json that
# the pencere sqlpen is built with did not write.
DIST_FLAGS ?=
sums:
	cd dist/release && { sha256sum sqlpen-* 2>/dev/null || shasum -a 256 sqlpen-*; } > SHA256SUMS
	@cat dist/release/SHA256SUMS
	@test -x "$(PENCERE)" || { echo "sums: no pencere at $(PENCERE): make pencere, or PENCERE=<a pencere command that has dist>"; exit 1; }
	"$(PENCERE)" dist --files dist/release --describe-args --demo $(DIST_FLAGS) $(PACKAGE_VERSION)

# release-prepare sets the version and dates the changelog's Unreleased section.
release-prepare:
	@test -n "$(VERSION)" || { echo "usage: make release-prepare VERSION=<x.y.z>"; exit 2; }
	node tools/release.mjs prepare $(VERSION)

# release runs the gate and the release checks (dist/release holds the three files of this
# version and their SHA256SUMS, made after the release commit), then tags. Nothing is pushed.
release: check
	node tools/release.mjs tag

# publish pushes main and the tag, then makes the GitHub release with the three files and
# SHA256SUMS. Publishing: run on the maintainer's word.
publish:
	node tools/release.mjs publish
