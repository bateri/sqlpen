# Releasing

A release is three files on a GitHub release tagged `v<x.y.z>`, `sqlpen-<version>-<target>` for
macOS on Apple silicon and Linux on arm64 and x86_64 (linked statically, with musl), with a
`SHA256SUMS`. There is no Intel Mac file, because bateri runs on Apple silicon only. People install
it with `install.sh` (see the README).

Each file is the Rust program with its page (`src/view/`, `src/assets/`) carried in it, SQLite built
in. The release workflow builds each on a runner of its own system and architecture, with the
toolchain the gate runs with (Rust 1.88), from nothing.

## Versions and the changelog

[Semantic versioning](https://semver.org/); while it is `0.x`, a minor release may change behaviour.
Every change a user would notice goes under `## [Unreleased]` in `CHANGELOG.md`, in the same commit
as the change.

## pencere

sqlpen is built against the `pencere` crate, and its page is tested on the kit's crates of the same
pencere; `Cargo.lock` is the one place pencere is pinned. While sqlpen needs what pencere's `main`
has and no release of it does, `Cargo.toml` takes every pencere crate from git at one commit
(`rev = "…"`, written whole). `make dev` takes the `pencere` command it runs sqlpen under from the
same pencere: `make pencere` fetches the commit, or the tag `crates-v<version>` of a release on
crates.io, that `Cargo.lock` names (`node tools/release.mjs pencere-ref`) into `.cache/pencere` and
builds it there. Nothing else says which pencere: moving it is a change of `Cargo.toml` and
`Cargo.lock`.

A release of sqlpen is built with that pencere, a commit or a release alike: Cargo builds it into
each file from the source `Cargo.lock` names, on the file's own runner, and nothing of pencere's is
downloaded ready-made. `make rehearse` says which pencere it is.

## A release

1. `make release-prepare VERSION=<x.y.z>` sets the version in `Cargo.toml` and `Cargo.lock` and
   dates the changelog. Commit it as `Release sqlpen <x.y.z>` and push it to `main`.
2. The gate (`check.yml`) runs on the push. When it is green, the release workflow
   (`release.yml`) starts.
3. If the version has no tag yet, the workflow checks the version and changelog, builds the three
   files, sums them, checks them and records their provenance, pushes the tag, and writes a
   **draft** GitHub release.
   Before the first release, while the changelog has no release section, a push releases nothing.
4. The run waits in the `release` environment. GitHub notifies the reviewers; one of them opens
   the run and chooses **Review deployments → Approve**. The workflow then checks the files again
   and makes the draft public as **Latest**. Rejected, nothing is published.
5. Check it: `gh release view v<x.y.z>`, and run `install.sh` on a machine.

**If something fails.** Before the tag, nothing is public: fix it and push again. A tag is never
moved; a broken release is followed by a new version. A release that stopped after its tag is
finished by running the workflow by hand on `main` (**Run workflow**, or
`gh workflow run release.yml`).

**Trying it.** `make rehearse` runs the release checks on any branch. **Run workflow** with
**rehearse** builds on any branch and publishes nothing.

### What the checks refuse

- a `Cargo.lock` that takes pencere's packages from more than one place;
- a version that is not after the last, or a `Cargo.toml` that disagrees with the changelog;
- a non-empty `## [Unreleased]`, or an empty release section;
- a commit whose gate is not green, a tag on another commit, or a release that is public already;
- files that are not exactly the three executables of this version with correct sums and this
  workflow's attestation; on its own machine, an executable that does not say it is this version.

## Settings the workflow relies on

GitHub → Settings → Environments → `release`: **Required reviewers**, and deployments from `main`
only. There is no secret or token. The publishing job refuses to run if the environment has no
reviewers, because GitHub would otherwise create it empty and publish without asking.
