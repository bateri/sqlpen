// The installer, `install.sh`, run as a person runs it, against a directory that stands in for
// GitHub (`SQLPEN_DOWNLOAD_BASE`): a listing of releases, and for each release its files and
// SHA256SUMS. Nothing here reaches the network, and nothing writes outside a temporary directory:
// HOME and the install directory are the test's own.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";

/** The few of vitest's matchers these tests were written with, over node's assert. */
const expect = (actual) => ({
  toBe: (expected) => assert.equal(actual, expected),
  toEqual: (expected) => assert.deepEqual(actual, expected),
  toContain: (part) =>
    assert.ok(actual.includes(part), `${JSON.stringify(part)} is not in ${JSON.stringify(actual)}`),
  not: {
    toContain: (part) =>
      assert.ok(!actual.includes(part), `${JSON.stringify(part)} is in ${JSON.stringify(actual)}`),
  },
});

const script = join(dirname(fileURLToPath(import.meta.url)), "..", "install.sh");

/** The target the script picks on the machine the test runs on. */
const target = `${process.arch === "arm64" ? "aarch64" : "x86_64"}-${
  process.platform === "darwin" ? "apple-darwin" : "unknown-linux-musl"
}`;

const dirs = [];
afterEach(() => {
  while (dirs.length > 0) rmSync(dirs.pop(), { recursive: true, force: true });
});
const scratch = () => {
  const dir = mkdtempSync(join(tmpdir(), "sqlpen-install-test-"));
  dirs.push(dir);
  return dir;
};

const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

/** A release of the listing, in the order GitHub gives its keys. */
const release = (tag, { draft = false, prerelease = false, files = [] } = {}) => ({
  url: `https://api.github.com/repos/bateri/sqlpen/releases/1`,
  author: { login: "someone", site_admin: false },
  tag_name: tag,
  target_commitish: "main",
  name: tag,
  draft,
  immutable: false,
  prerelease,
  created_at: "2026-01-01T00:00:00Z",
  // What a release says of itself can hold anything, including what looks like a release.
  body: `Notes, with commas, and "tag_name": "v99.0.0", "draft": false`,
  assets: ["SHA256SUMS", ...files].map((name) => ({
    name,
    state: "uploaded",
    uploader: { login: "bot" },
  })),
});

/**
 * A stand-in for GitHub: `releases.json` lists `tags`, and each of `versions` has the stub
 * executable for the machine's target, whose output names its version, with its SHA256SUMS. A
 * tag given as a string lists that file among its release's files when its version is one of
 * `versions`.
 */
function github({ tags = [], versions = [], pretty = true, sums } = {}) {
  const base = scratch();
  const files = (tag) => {
    const version = tag.startsWith("v") ? tag.slice("v".length) : null;
    return versions.includes(version) ? [`sqlpen-${version}-${target}`] : [];
  };
  const listing = tags.map((tag) =>
    typeof tag === "string" ? release(tag, { files: files(tag) }) : tag,
  );
  writeFileSync(join(base, "releases.json"), JSON.stringify(listing, null, pretty ? 2 : undefined));
  for (const version of versions) {
    const dir = join(base, `v${version}`);
    mkdirSync(dir);
    const file = `sqlpen-${version}-${target}`;
    const bytes = `#!/bin/sh\necho "sqlpen ${version}"\n`;
    writeFileSync(join(dir, file), bytes);
    const line = sums?.(file, bytes) ?? `${sha256(bytes)}  ${file}\n`;
    writeFileSync(join(dir, "SHA256SUMS"), line);
  }
  return base;
}

/** Runs the script with an environment of its own: only what it is given, and a PATH. */
function install(base, env = {}, { path } = {}) {
  const home = scratch();
  const into = join(home, "bin");
  const done = spawnSync("sh", [script], {
    encoding: "utf8",
    env: {
      PATH: path ?? process.env.PATH,
      HOME: home,
      TMPDIR: tmpdir(),
      SQLPEN_INSTALL: into,
      SQLPEN_DOWNLOAD_BASE: `file://${base}`,
      ...env,
    },
  });
  return { status: done.status, out: done.stdout, err: done.stderr, into };
}

const installed = (into) => join(into, "sqlpen");

describe("install.sh", () => {
  it("installs the release, runs, and says where it put it", () => {
    const base = github({ tags: ["v0.2.0"], versions: ["0.2.0"] });
    const done = install(base);
    expect(done.err).toBe("");
    expect(done.status).toBe(0);
    expect(done.out).toContain(`installed sqlpen 0.2.0 (${target}) to ${installed(done.into)}`);
    expect(statSync(installed(done.into)).mode & 0o777).toBe(0o755);
    const ran = spawnSync(installed(done.into), { encoding: "utf8" });
    expect(ran.stdout).toBe("sqlpen 0.2.0\n");
    // Nothing but the command was put there.
    expect(readFileSync(installed(done.into), "utf8")).toContain("sqlpen 0.2.0");
  });

  it("hints at the PATH when the directory is not on it, and only then", () => {
    const base = github({ tags: ["v0.2.0"], versions: ["0.2.0"] });
    const off = install(base);
    expect(off.out).toContain("is not on your PATH");
    expect(off.out).toContain(`export PATH="${off.into}:$PATH"`);
    const home = scratch();
    const into = join(home, "bin");
    const on = spawnSync("sh", [script], {
      encoding: "utf8",
      env: {
        PATH: `${into}:${process.env.PATH}`,
        HOME: home,
        SQLPEN_INSTALL: into,
        SQLPEN_DOWNLOAD_BASE: `file://${base}`,
      },
    });
    expect(on.status).toBe(0);
    expect(on.stdout).not.toContain("PATH");
  });

  it("refuses a file whose sum is not the one in SHA256SUMS, and installs nothing", () => {
    const base = github({
      tags: ["v0.2.0"],
      versions: ["0.2.0"],
      sums: (file) => `${"0".repeat(64)}  ${file}\n`,
    });
    const done = install(base);
    expect(done.status).toBe(1);
    expect(done.err).toContain("is not the file SHA256SUMS of v0.2.0 has the sum of");
    expect(done.err).toContain("nothing was installed");
    expect(existsSync(installed(done.into))).toBe(false);
    // Not even the directory was made.
    expect(existsSync(done.into)).toBe(false);
  });

  it("refuses SHA256SUMS that does not name the file, and one that names it twice", () => {
    const other = github({
      tags: ["v0.2.0"],
      versions: ["0.2.0"],
      sums: (_, bytes) => `${sha256(bytes)}  sqlpen-0.2.0-another-target\n`,
    });
    const missing = install(other);
    expect(missing.status).toBe(1);
    expect(missing.err).toContain("does not name");
    expect(existsSync(installed(missing.into))).toBe(false);

    const twice = github({
      tags: ["v0.2.0"],
      versions: ["0.2.0"],
      sums: (file, bytes) => `${sha256(bytes)}  ${file}\n${sha256(bytes)}  ${file}\n`,
    });
    const done = install(twice);
    expect(done.status).toBe(1);
    expect(existsSync(installed(done.into))).toBe(false);
  });

  it("takes the version SQLPEN_VERSION names, and the listing is not read", () => {
    // No listing at all: asking for a version never asks which is the newest.
    const base = github({ versions: ["0.1.5", "0.3.0"] });
    rmSync(join(base, "releases.json"));
    const done = install(base, { SQLPEN_VERSION: "0.1.5" });
    expect(done.status).toBe(0);
    expect(spawnSync(installed(done.into), { encoding: "utf8" }).stdout).toBe("sqlpen 0.1.5\n");
    const withV = install(base, { SQLPEN_VERSION: "v0.3.0" });
    expect(spawnSync(installed(withV.into), { encoding: "utf8" }).stdout).toBe("sqlpen 0.3.0\n");
  });

  it("refuses a version that is not one", () => {
    const base = github({ versions: ["0.2.0"] });
    const done = install(base, { SQLPEN_VERSION: "../0.2.0" });
    expect(done.status).toBe(1);
    expect(done.err).toContain("is not a version");
  });

  for (const pretty of [true, false]) {
    it(`takes the newest release of the command from a listing of every line's (pretty ${pretty})`, () => {
      const base = github({
        pretty,
        tags: [
          // Out of order, and among the tags of other lines, a draft and a pre-release.
          "v0.9.0",
          "sdk-typescript-v9.0.0",
          "crates-v0.10.0",
          release("v9.9.9", { draft: true }),
          "v0.10.0",
          release("v1.0.0-rc.1", { prerelease: true }),
          release("v2.0.0", { prerelease: true }),
          "v0.2.0",
          "cli-latest",
        ],
        versions: ["0.10.0", "0.9.0", "9.9.9"],
      });
      const done = install(base);
      expect(done.err).toBe("");
      expect(done.status).toBe(0);
      expect(done.out).toContain("installed sqlpen 0.10.0");
      expect(spawnSync(installed(done.into), { encoding: "utf8" }).stdout).toBe(
        "sqlpen 0.10.0\n",
      );
    });
  }

  it("says so when the repository has no release of the command", () => {
    const base = github({
      tags: ["sdk-typescript-v0.1.1", release("v0.2.0", { draft: true })],
    });
    const done = install(base);
    expect(done.status).toBe(1);
    expect(done.err).toContain(`has no release of sqlpen for ${target} yet`);
  });

  it("passes over a release of the tag's line that has no file for the machine", () => {
    // `v0.1.0` was another package's release: it has files, none of them this command.
    const old = github({
      tags: [release("v0.1.0", { files: ["sqlpen-cli-0.1.0.tgz"] })],
    });
    const none = install(old);
    expect(none.status).toBe(1);
    expect(none.err).toContain(`has no release of sqlpen for ${target} yet`);
    expect(none.err).not.toContain("0.1.0");
    expect(existsSync(none.into)).toBe(false);

    // A newer release that lacks this machine's file gives way to the newest that has it.
    const base = github({
      tags: [release("v0.3.0", { files: ["sqlpen-0.3.0-some-other-target"] }), "v0.2.0"],
      versions: ["0.2.0"],
    });
    const done = install(base);
    expect(done.err).toBe("");
    expect(done.status).toBe(0);
    expect(done.out).toContain("installed sqlpen 0.2.0");
  });

  it("says what is missing when the release has no file for the machine", () => {
    // Asked for by version, the release is not looked up in the listing: the download says it.
    const base = github({ tags: ["v0.2.0"], versions: [] });
    mkdirSync(join(base, "v0.2.0"));
    const done = install(base, { SQLPEN_VERSION: "0.2.0" });
    expect(done.status).toBe(1);
    expect(done.err).toContain(`sqlpen-0.2.0-${target}`);
    expect(done.err).toContain("v0.2.0");
  });

  it("replaces an installed command whole, and leaves nothing beside it", () => {
    const base = github({ tags: ["v0.2.0"], versions: ["0.2.0"] });
    const home = scratch();
    const into = join(home, "bin");
    mkdirSync(into);
    writeFileSync(installed(into), "old");
    chmodSync(installed(into), 0o755);
    const done = spawnSync("sh", [script], {
      encoding: "utf8",
      env: {
        PATH: process.env.PATH,
        HOME: home,
        SQLPEN_INSTALL: into,
        SQLPEN_DOWNLOAD_BASE: `file://${base}`,
      },
    });
    expect(done.status).toBe(0);
    expect(readFileSync(installed(into), "utf8")).toContain("sqlpen 0.2.0");
    expect(readdirSync(into)).toEqual(["sqlpen"]);
  });

  it("installs under HOME when SQLPEN_INSTALL is not set", () => {
    const base = github({ tags: ["v0.2.0"], versions: ["0.2.0"] });
    const home = scratch();
    const done = spawnSync("sh", [script], {
      encoding: "utf8",
      env: { PATH: process.env.PATH, HOME: home, SQLPEN_DOWNLOAD_BASE: `file://${base}` },
    });
    expect(done.status).toBe(0);
    expect(existsSync(join(home, ".local", "bin", "sqlpen"))).toBe(true);
  });

  describe("on a machine it has no file for", () => {
    /** A `uname` that answers as the machine it stands for. */
    const as = (system, processor) => {
      const bin = scratch();
      writeFileSync(
        join(bin, "uname"),
        `#!/bin/sh\ncase "$1" in -s) echo ${system} ;; -m) echo ${processor} ;; esac\n`,
      );
      chmodSync(join(bin, "uname"), 0o755);
      // And a `sysctl` of a Mac that is not Apple silicon, so that a test run on one is not taken
      // for a shell under Rosetta.
      writeFileSync(join(bin, "sysctl"), "#!/bin/sh\necho 0\n");
      chmodSync(join(bin, "sysctl"), 0o755);
      return `${bin}:${process.env.PATH}`;
    };

    it("refuses a system with no release, and says which are", () => {
      const base = github({ tags: ["v0.2.0"], versions: ["0.2.0"] });
      const done = install(base, {}, { path: as("FreeBSD", "x86_64") });
      expect(done.status).toBe(1);
      expect(done.err).toContain("there is no sqlpen for FreeBSD");
      expect(done.err).toContain("macOS and Linux");
      expect(existsSync(done.into)).toBe(false);
    });

    it("refuses a processor with no release", () => {
      const base = github({ tags: ["v0.2.0"], versions: ["0.2.0"] });
      const done = install(base, {}, { path: as("Linux", "riscv64") });
      expect(done.status).toBe(1);
      expect(done.err).toContain("there is no sqlpen for a riscv64 processor");
    });

    it("refuses an Intel Mac, which bateri does not run on", () => {
      const base = github({ tags: ["v0.2.0"], versions: ["0.2.0"] });
      const done = install(base, {}, { path: as("Darwin", "x86_64") });
      expect(done.status).toBe(1);
      expect(done.err).toContain("there is no sqlpen for an Intel Mac");
    });

    it("asks for the Linux file on Linux, whatever the processor is called", () => {
      for (const [processor, arch] of [
        ["aarch64", "aarch64"],
        ["arm64", "aarch64"],
        ["x86_64", "x86_64"],
        ["amd64", "x86_64"],
      ]) {
        const base = scratch();
        writeFileSync(join(base, "releases.json"), JSON.stringify([release("v0.2.0")]));
        mkdirSync(join(base, "v0.2.0"));
        const done = install(base, {}, { path: as("Linux", processor) });
        // The release has no file for any machine, so none is installed, and the error names the
        // machine the script looked for.
        expect(done.err, processor).toContain(`for ${arch}-unknown-linux-musl yet`);
      }
    });
  });
});
