// Releases sqlpen: one script for every step a machine can check, so a release is the same
// sequence every time. RELEASING.md is the procedure, this file the checks.
//
// On a maintainer's machine:
//
//   prepare <version>   set the version, move Unreleased into a dated section of CHANGELOG.md; the
//                       commit of it, pushed to main, is what starts a release
//   rehearse            everything a release of the prepared version checks, on any branch
//   notes [<version>]   the CHANGELOG section of a version
//   version             the version sqlpen says it is (Cargo.toml)
//   pencere-ref         the commit or release tag of pencere that Cargo.lock takes it at, which the
//                       Makefile fetches the `pencere` command `make dev` runs sqlpen under at
//
// In the release workflow (.github/workflows/release.yml), after the gate is green on main:
//
//   plan                whether this commit's version has no tag yet (or, started by hand, has one
//                       on this commit and a draft to finish): what the workflow reads
//   dist [dir]          the files of a release in dir (dist/release), checked: the three
//                       executables of this version and the SHA256SUMS that names them
//   tag                 the annotated tag v<version> on this commit, pushed
//   draft [dir]         the GitHub release of the tag as a draft, with the notes and the files
//   publish             once a maintainer has approved: the draft's files checked against their
//                       sums and attestations, and the draft made public as the Latest
//
// It uses nothing but Node, git and gh.

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const NAME = "sqlpen";

/** The systems sqlpen is built for (the Makefile's TARGETS, the release workflow's builds). */
const TARGETS = ["aarch64-apple-darwin", "aarch64-unknown-linux-musl", "x86_64-unknown-linux-musl"];

/** Where `make dist` puts the files of a release. */
const RELEASE_DIR = join(root, "dist", "release");

const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?$/;
const RELEASED = /^## \[(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\] - (\d{4}-\d{2}-\d{2})$/;

class Refusal extends Error {}
const refuse = (what) => {
  throw new Refusal(what);
};

/** Runs a command and returns its output; one run with `stdio: "inherit"` returns "". */
function run(command, args, options = {}) {
  const output = execFileSync(command, args, {
    cwd: root,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    ...options,
  });
  return (output ?? "").trim();
}

function succeeds(command, args, options = {}) {
  try {
    run(command, args, options);
    return true;
  } catch {
    return false;
  }
}

const tagOf = (version) => `v${version}`;

// ---- the version ---------------------------------------------------------------

/** The version of sqlpen: the package's, in Cargo.toml, and the lockfile's entry for it. */
const MANIFEST = join(root, "Cargo.toml");
const LOCKFILE = join(root, "Cargo.lock");
const PACKAGE_VERSION = /^(\[package\][^[]*?\nversion = ")([^"]+)(")/m;
const LOCKED_VERSION = /(\[\[package\]\]\nname = "sqlpen"\nversion = ")([^"]+)(")/;

function versionOf() {
  const version = PACKAGE_VERSION.exec(readFileSync(MANIFEST, "utf8"))?.[2];
  if (version === undefined) refuse("Cargo.toml does not say a version");
  return version;
}

function setVersion(version) {
  writeFileSync(MANIFEST, readFileSync(MANIFEST, "utf8").replace(PACKAGE_VERSION, `$1${version}$3`));
  const lock = readFileSync(LOCKFILE, "utf8");
  if (!LOCKED_VERSION.test(lock)) refuse("Cargo.lock has no entry for sqlpen: run cargo build first");
  writeFileSync(LOCKFILE, lock.replace(LOCKED_VERSION, `$1${version}$3`));
}

// ---- pencere ---------------------------------------------------------------

/**
 * pencere as Cargo.lock has it: each of its packages (`pencere`, `pencere-wire`, the kit's crates
 * the page's tests run on) and the source it is taken from, a commit of the repository or a release
 * on crates.io. Cargo.lock is the one place pencere is pinned: the program is built from it, the
 * page's tests run in its interpreter and editors, and the `pencere` command of `make dev` is
 * fetched at the same pencere.
 */
const LOCKED_PENCERE = /\[\[package\]\]\nname = "(pencere(?:-[a-z]+)*)"\nversion = "([^"]+)"\nsource = "([^"]+)"/g;
const PENCERE_GIT = /^git\+https:\/\/github\.com\/bateri\/pencere(?:\?[^#]*)?#([0-9a-f]{40})$/;
const CRATES_IO = "registry+https://github.com/rust-lang/crates.io-index";

function pencereLocked() {
  const packages = [...readFileSync(LOCKFILE, "utf8").matchAll(LOCKED_PENCERE)].map(
    ([, name, version, source]) => ({ name, version, source }),
  );
  const pencere = packages.find((p) => p.name === "pencere");
  if (pencere === undefined) refuse("Cargo.lock takes no pencere: run cargo build first");
  const other = packages.find((p) => p.source !== pencere.source || p.version !== pencere.version);
  if (other !== undefined) {
    refuse(
      `Cargo.lock takes ${other.name} ${other.version} from ${other.source}, and pencere ${pencere.version} from ${pencere.source}: one pencere, from one place`,
    );
  }
  const commit = PENCERE_GIT.exec(pencere.source)?.[1];
  if (commit !== undefined) return { commit };
  if (pencere.source === CRATES_IO) return { version: pencere.version };
  refuse(`Cargo.lock takes pencere from ${pencere.source}, neither bateri/pencere nor crates.io`);
}

/** The git ref of pencere the Makefile fetches: the commit, or the tag of the crates' release. */
function pencereRef() {
  const { commit, version } = pencereLocked();
  return commit ?? `crates-v${version}`;
}

// ---- the changelog ---------------------------------------------------------

const changelogPath = join(root, "CHANGELOG.md");

/** The changelog as its heading lines and the sections below them. */
function sections() {
  const lines = readFileSync(changelogPath, "utf8").split("\n");
  const found = [];
  lines.forEach((text, index) => {
    if (text.startsWith("## ")) found.push({ heading: text, start: index });
  });
  return found.map((section, i) => ({
    ...section,
    end: i + 1 < found.length ? found[i + 1].start : lines.length,
    body: lines
      .slice(section.start + 1, i + 1 < found.length ? found[i + 1].start : lines.length)
      .join("\n")
      .trim(),
  }));
}

function unreleased() {
  const first = sections()[0];
  if (first === undefined || first.heading !== "## [Unreleased]") {
    refuse(`CHANGELOG.md: the first section must be "## [Unreleased]"`);
  }
  return first;
}

function releasedSection(version) {
  const section = sections().find((s) => RELEASED.exec(s.heading)?.[1] === version);
  if (section === undefined) refuse(`CHANGELOG.md: no "## [${version}] - YYYY-MM-DD" section`);
  if (section.body === "") refuse(`CHANGELOG.md: the section of ${version} is empty`);
  return section;
}

function compare(a, b) {
  const pa = SEMVER.exec(a);
  const pb = SEMVER.exec(b);
  for (let i = 1; i <= 3; i++) {
    const d = Number(pa[i]) - Number(pb[i]);
    if (d !== 0) return d;
  }
  // A pre-release sorts before the release it leads to.
  if (pa[4] === undefined) return pb[4] === undefined ? 0 : 1;
  if (pb[4] === undefined) return -1;
  return pa[4] < pb[4] ? -1 : pa[4] > pb[4] ? 1 : 0;
}

// ---- commands ----------------------------------------------------------------

function prepare(version) {
  if (!SEMVER.test(version ?? "")) refuse(`"${version}" is not a version (x.y.z)`);
  const current = versionOf();
  if (compare(version, current) <= 0) refuse(`${version} is not after ${current}`);
  const top = unreleased();
  if (top.body === "") refuse("CHANGELOG.md: Unreleased is empty, nothing to release");
  if (sections().some((s) => RELEASED.exec(s.heading)?.[1] === version)) {
    refuse(`CHANGELOG.md already has a section for ${version}`);
  }
  const date = new Date().toISOString().slice(0, 10);
  const lines = readFileSync(changelogPath, "utf8").split("\n");
  lines.splice(top.start, 1, "## [Unreleased]", "", `## [${version}] - ${date}`);
  writeFileSync(changelogPath, lines.join("\n"));
  setVersion(version);
  console.log(`${NAME} ${current} -> ${version}`);
  console.log(
    `next: review, commit ("Release ${NAME} ${version}") and push to main: the release workflow takes it from there`,
  );
}

/**
 * What the version must be to be released: prepared (a dated section, nothing left under
 * Unreleased) and after the last release's tag. Asks nothing but the files and the tags.
 */
function versionChecks() {
  const version = versionOf();
  if (!SEMVER.test(version ?? "") || version === "0.0.0") {
    refuse(`Cargo.toml is at "${version}": run make release-prepare first`);
  }
  if (unreleased().body !== "") {
    refuse("CHANGELOG.md: Unreleased is not empty; prepare moves it into the release");
  }
  const section = sections().find((s) => RELEASED.test(s.heading));
  if (section === undefined || RELEASED.exec(section.heading)[1] !== version) {
    refuse(`CHANGELOG.md: the newest section is not ${version}`);
  }
  releasedSection(version);
  const last = run("git", ["tag", "--list", "v*"])
    .split("\n")
    .map((name) => name.slice(1))
    .filter((v) => SEMVER.test(v) && v !== version)
    .sort(compare)
    .at(-1);
  if (last !== undefined && compare(version, last) <= 0) {
    refuse(`${version} is not after ${last}, the last release`);
  }
  return { version, tag: tagOf(version), section };
}

const tagExists = (tag) =>
  succeeds("git", ["rev-parse", "--verify", "--quiet", `refs/tags/${tag}`]);
const tagIsHead = (tag) =>
  run("git", ["rev-list", "-n", "1", tag]) === run("git", ["rev-parse", "HEAD"]);

/** `isDraft` of the GitHub release of a tag, or "none". */
function releaseState(tag) {
  try {
    return JSON.parse(run("gh", ["release", "view", tag, "--json", "isDraft"])).isDraft
      ? "draft"
      : "public";
  } catch (error) {
    if (String(error.stderr ?? "").includes("release not found")) return "none";
    refuse(
      `cannot ask GitHub about the release ${tag}: ${String(error.stderr ?? error.message).trim()}`,
    );
  }
}

/** Everything a release of the prepared version checks, on any branch: what `make rehearse` runs. */
function rehearse() {
  const pencere = pencereRef();
  const { version, tag } = versionChecks();
  if (tagExists(tag)) refuse(`the tag ${tag} exists`);
  console.log(`${NAME} ${version} is ready to be released as ${tag}, with pencere ${pencere}`);
}

/** The run of the gate (check.yml) for the commit, on main, must have finished, and well. */
function requireGreenCheck(sha) {
  const runs = JSON.parse(
    run("gh", [
      "run",
      "list",
      "--workflow",
      "check.yml",
      "--event",
      "push",
      "--branch",
      "main",
      "--commit",
      sha,
      "--limit",
      "10",
      "--json",
      "databaseId,status,conclusion",
    ]),
  );
  const [latest] = runs;
  if (latest === undefined) refuse(`no run of the gate for ${sha.slice(0, 7)} on main`);
  if (latest.status !== "completed") {
    refuse(
      `the gate's run ${latest.databaseId} for ${sha.slice(0, 7)} is ${latest.status}: wait for it`,
    );
  }
  if (latest.conclusion !== "success") {
    refuse(
      `the gate's run ${latest.databaseId} for ${sha.slice(0, 7)} ended in ${latest.conclusion}`,
    );
  }
}

/**
 * Whether to release this commit, for the workflow to read from its output file: its version has
 * no tag yet, or (started by hand, `RELEASE_RESUME`) has one on this commit whose release is a
 * draft still, to be finished. A commit whose version is tagged and not asked to resume is not a
 * release, whatever its changelog has gone on to.
 */
function plan() {
  const resume = process.env.RELEASE_RESUME === "true";
  if (process.env.RELEASE_REQUIRE_CHECK === "true")
    requireGreenCheck(run("git", ["rev-parse", "HEAD"]));
  const version = versionOf();
  let release = true;
  if (tagExists(tagOf(version)) && !resume) {
    console.error(`${tagOf(version)} exists: nothing to release`);
    release = false;
  } else if (!resume && !sections().some((s) => RELEASED.test(s.heading))) {
    // Never released, and no release prepared: a push of the work before the first one.
    console.error("CHANGELOG.md has no release section yet: nothing to release");
    release = false;
  } else {
    const { tag } = versionChecks();
    if (tagExists(tag)) {
      if (!tagIsHead(tag)) refuse(`${tag} is on another commit: a tag is never moved`);
      if (releaseState(tag) === "public") refuse(`the GitHub release ${tag} is public already`);
    }
    console.error(`${NAME} ${version} is to be released as ${tag}`);
  }
  // Read by the workflow from its output file.
  console.log(`release=${release}`);
  console.log(`version=${version}`);
  console.log(`tag=${tagOf(version)}`);
}

/** The files of a release in `dir`, checked: what the workflow attests and the draft carries. */
function dist(dir) {
  const files = releaseFiles(versionOf(), dir ? resolve(dir) : RELEASE_DIR, { execute: true });
  console.log(`${files.length} files of ${NAME} ${versionOf()}: ${files.join(", ")}`);
}

/** The executable of a release for a target. */
const fileOf = (version, target) => `${NAME}-${version}-${target}`;

/** The target of the machine this runs on, for the one executable it can run. */
function ownTarget() {
  const arch = { arm64: "aarch64", x64: "x86_64" }[process.arch];
  if (arch === undefined) return undefined;
  if (process.platform === "darwin") return `${arch}-apple-darwin`;
  if (process.platform === "linux") return `${arch}-unknown-linux-musl`;
  return undefined;
}

/**
 * The files `make dist` made for this version: the three executables and the SHA256SUMS that names
 * exactly them, each with the sum it lists. The names carry the version, so a dist/release made
 * before the version moved is refused; with `execute`, the one executable this machine can run says
 * its version.
 */
function releaseFiles(version, dir = RELEASE_DIR, { execute = false } = {}) {
  if (!existsSync(dir)) refuse(`no ${dir}: make dist, after the release commit`);
  const expected = TARGETS.map((target) => fileOf(version, target));
  const found = readdirSync(dir).sort();
  const wanted = [...expected, "SHA256SUMS"].sort();
  if (found.join("\n") !== wanted.join("\n")) {
    refuse(
      `the release's directory holds ${found.join(", ") || "nothing"} and a release of ${version} is ${wanted.join(", ")}: make dist again, after the release commit`,
    );
  }
  const listed = new Map(
    readFileSync(join(dir, "SHA256SUMS"), "utf8")
      .split("\n")
      .filter((line) => line.trim() !== "")
      .map((line) => {
        const [sum, name] = line.split(/\s+/);
        return [name.replace(/^\*/, ""), sum];
      }),
  );
  if ([...listed.keys()].sort().join("\n") !== [...expected].sort().join("\n")) {
    refuse("SHA256SUMS does not name exactly the three executables");
  }
  for (const name of expected) {
    const sum = createHash("sha256")
      .update(readFileSync(join(dir, name)))
      .digest("hex");
    if (listed.get(name) !== sum)
      refuse(`${name} is not the file SHA256SUMS lists: make dist again`);
  }
  // Where the files were made (a download or an artifact keeps no mode, so only there).
  const own = execute ? ownTarget() : undefined;
  if (own !== undefined) {
    const said = run(join(dir, fileOf(version, own)), ["--version"]);
    if (said !== `${NAME} ${version}`)
      refuse(`${fileOf(version, own)} says it is ${said}: make dist again`);
  }
  return [...expected, "SHA256SUMS"];
}

/** The annotated tag of the version on this commit, pushed; left as it is if it is there. */
function tag() {
  const { version, tag: tagName, section } = versionChecks();
  if (tagExists(tagName)) {
    if (!tagIsHead(tagName)) refuse(`${tagName} is on another commit: a tag is never moved`);
    console.log(`${tagName} is on this commit already`);
    return;
  }
  // Verbatim: the default cleanup would take the section's "### Added" lines for comments.
  const message = `${NAME} ${version}\n\n${section.body}\n`;
  run("git", ["tag", "--annotate", "--cleanup=verbatim", tagName, "--message", message]);
  run("git", ["push", "--quiet", "origin", `refs/tags/${tagName}`], {
    stdio: "inherit",
  });
  console.log(`tagged ${tagName} and pushed it`);
}

/** The GitHub release of the tag as a draft: the changelog section, the files. Made again if a draft is there. */
function draft(dir) {
  const version = versionOf();
  const tagName = tagOf(version);
  const files = releaseFiles(version, dir ? resolve(dir) : RELEASE_DIR).map((name) =>
    join(dir ? resolve(dir) : RELEASE_DIR, name),
  );
  const state = releaseState(tagName);
  if (state === "public")
    refuse(`the GitHub release ${tagName} is public already: it is never touched`);
  if (state === "draft") run("gh", ["release", "delete", tagName, "--yes"]);
  // `--verify-tag`: the release is made on the tag that was pushed, never on a tag gh would make.
  execFileSync(
    "gh",
    [
      "release",
      "create",
      tagName,
      "--verify-tag",
      "--draft",
      "--title",
      tagName,
      "--notes-file",
      "-",
      ...files,
    ],
    {
      cwd: root,
      input: releasedSection(version).body,
      stdio: ["pipe", "inherit", "inherit"],
    },
  );
  console.log(`made the draft of ${tagName} with ${files.length} files`);
}

/**
 * Makes the draft public, as the repository's Latest, once its files are the ones built: the
 * sums, and the attestation that this repository's release workflow built each. What the workflow
 * does once a maintainer has approved it.
 */
/**
 * The environment the workflow publishes in (`RELEASE_ENVIRONMENT`, "release") must have someone
 * who approves: GitHub makes an environment a job names and that is not there, with no rule, and
 * runs the job at once, so a release would be public with nobody's word . A run
 * outside the workflow (no `RELEASE_ENVIRONMENT`) is not asked.
 */
function requireReviewers() {
  const environment = process.env.RELEASE_ENVIRONMENT;
  if (environment === undefined || environment === "") return;
  const repo =
    process.env.GITHUB_REPOSITORY ||
    run("gh", ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]);
  let rules;
  try {
    rules = JSON.parse(
      run("gh", ["api", `repos/${repo}/environments/${environment}`]),
    ).protection_rules;
  } catch (error) {
    refuse(
      `cannot ask GitHub about the environment ${environment}: ${String(error.stderr ?? error.message).trim()}`,
    );
  }
  const reviewers = (rules ?? [])
    .filter((rule) => rule.type === "required_reviewers")
    .flatMap((rule) => rule.reviewers ?? []);
  if (reviewers.length === 0) {
    refuse(
      `the environment ${environment} has no required reviewers, so nobody approved this: add them in the repository's Settings, Environments, ${environment}, then run the workflow again (RELEASING.md)`,
    );
  }
}

function publish() {
  requireReviewers();
  const version = versionOf();
  const tagName = tagOf(version);
  if (!tagExists(tagName)) refuse(`no tag ${tagName}: the workflow tags before it publishes`);
  if (!tagIsHead(tagName)) refuse(`${tagName} is not on this commit`);
  const state = releaseState(tagName);
  if (state === "none") refuse(`${tagName} has no GitHub release: the workflow writes the draft`);
  if (state === "public") refuse(`the GitHub release ${tagName} is public already`);
  const dir = mkdtempSync(join(tmpdir(), "sqlpen-publish-"));
  try {
    run("gh", ["release", "download", tagName, "--dir", dir, "--pattern", "*"], {
      stdio: "inherit",
    });
    const files = releaseFiles(version, dir);
    const repo = run("gh", ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]);
    for (const file of files) {
      run(
        "gh",
        [
          "attestation",
          "verify",
          join(dir, file),
          "--repo",
          repo,
          "--signer-workflow",
          `${repo}/.github/workflows/release.yml`,
        ],
        { stdio: "inherit" },
      );
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  run("gh", ["release", "edit", tagName, "--draft=false", "--latest"], {
    stdio: "inherit",
  });
  console.log(`${NAME} ${version} is public: ${tagName}`);
}

function notes(version) {
  console.log(releasedSection(version ?? versionOf()).body);
}

function version() {
  console.log(versionOf());
}

function pencereRefCommand() {
  console.log(pencereRef());
}

const COMMANDS = {
  prepare,
  rehearse,
  plan,
  dist,
  tag,
  draft,
  publish,
  notes,
  version,
  "pencere-ref": pencereRefCommand,
};

const [command, ...args] = process.argv.slice(2);
const handler = COMMANDS[command];
if (handler === undefined) {
  console.error(`release: commands are ${Object.keys(COMMANDS).join(", ")}`);
  process.exit(2);
}
try {
  handler(...args);
} catch (error) {
  if (error instanceof Refusal) {
    console.error(`release: ${error.message}`);
    process.exit(1);
  }
  throw error;
}
