// The checks a release goes through (`tools/release-files.mjs`), run on a directory the test makes:
// the three executables, SHA256SUMS, and an app.json signed with a key made for the test and
// thrown away. Nothing here reaches the network, and nothing writes outside a temporary directory.

import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";

import { BATERI_KEY, TARGETS, Refusal, fileOf, ownTarget, releaseFiles } from "../tools/release-files.mjs";

const VERSION = "0.6.0";

const dirs = [];
afterEach(() => {
  while (dirs.length > 0) rmSync(dirs.pop(), { recursive: true, force: true });
});

/** A key made for one test: the signer, and the text `app.json` names it by. */
function newKey() {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const raw = publicKey.export({ format: "der", type: "spki" }).subarray(-32);
  return { privateKey, text: `ed25519:${raw.toString("base64")}` };
}

const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

/** The key each test release is signed with, by its directory: what `check` trusts for it. */
const trusted = new Map();

/** `releaseFiles`, trusting the key the test made for the directory (bateri's own if none). */
const check = (dir, version) => releaseFiles(dir, version, trusted.get(dir));

/** The files of a complete release in a new directory, and the means to make them wrong. */
function release(version = VERSION) {
  const dir = mkdtempSync(join(tmpdir(), "sqlpen-release-test-"));
  dirs.push(dir);
  const out = join(dir, "release");
  mkdirSync(out);
  const key = newKey();
  trusted.set(out, key.text);
  const sums = new Map();
  for (const target of TARGETS) {
    const name = fileOf(version, target);
    // A program that says its version, as the one this machine can run is asked to.
    const bytes = `#!/bin/sh\necho ${version}\n# ${target}\n`;
    writeFileSync(join(out, name), bytes);
    chmodSync(join(out, name), 0o755);
    sums.set(name, sha256(bytes));
  }
  const manifest = {
    name: "sqlpen",
    version,
    protocol: [1],
    views: [{ kind: "lua", versions: ["0.3"] }],
    key: key.text,
    files: Object.fromEntries(
      TARGETS.map((target) => {
        const name = fileOf(version, target);
        return [
          target,
          { url: `https://github.com/bateri/sqlpen/releases/download/v${version}/${name}`, sha256: sums.get(name) },
        ];
      }),
    ),
    previous: [],
  };
  const write = {
    sums: (map = sums) =>
      writeFileSync(join(out, "SHA256SUMS"), [...map].map(([name, sum]) => `${sum}  ${name}\n`).join("")),
    manifest: (value = manifest, signer = key.privateKey) => {
      const bytes = Buffer.from(JSON.stringify(value, null, 2));
      writeFileSync(join(out, "app.json"), bytes);
      writeFileSync(join(out, "app.json.sig"), `ed25519:${sign(null, bytes, signer).toString("base64")}\n`);
    },
  };
  write.sums();
  write.manifest();
  return { out, manifest, sums, key, write };
}

const refusal = (what) => (error) => {
  assert.ok(error instanceof Refusal, `${error}`);
  assert.ok(error.message.includes(what), `${JSON.stringify(what)} is not in ${JSON.stringify(error.message)}`);
  return true;
};

describe("the files of a release", () => {
  it("are the three executables, SHA256SUMS, app.json and its signature", () => {
    const { out } = release();
    assert.deepEqual(check(out, VERSION), [
      ...TARGETS.map((target) => fileOf(VERSION, target)),
      "SHA256SUMS",
      "app.json",
      "app.json.sig",
    ]);
  });

  it("are refused when app.json or its signature is missing", () => {
    for (const name of ["app.json", "app.json.sig"]) {
      const { out } = release();
      rmSync(join(out, name));
      assert.throws(() => check(out, VERSION), refusal(`dist/release holds`));
    }
  });

  it("are refused when something else is in the directory", () => {
    const { out } = release();
    writeFileSync(join(out, "notes.txt"), "not a file of the release");
    assert.throws(() => check(out, VERSION), refusal("notes.txt"));
  });

  it("are refused when app.json says another sum than SHA256SUMS, however well it is signed", () => {
    const { out, manifest, write } = release();
    const target = TARGETS[1];
    write.manifest({
      ...manifest,
      files: { ...manifest.files, [target]: { ...manifest.files[target], sha256: "0".repeat(64) } },
    });
    assert.throws(() => check(out, VERSION), refusal(`another sum for ${fileOf(VERSION, target)}`));
  });

  it("are refused when SHA256SUMS lists a sum the file does not have", () => {
    const { out, sums, write } = release();
    const name = fileOf(VERSION, TARGETS[0]);
    write.sums(new Map([...sums, [name, "0".repeat(64)]]));
    assert.throws(() => check(out, VERSION), refusal(`${name} is not the file SHA256SUMS lists`));
  });

  it("are refused when app.json is not what was signed", () => {
    const { out } = release();
    const bytes = readFileSync(join(out, "app.json"), "utf8");
    // One character of the version changed: still JSON, still of the shape.
    writeFileSync(join(out, "app.json"), bytes.replace('"protocol": [\n    1', '"protocol": [\n    2'));
    assert.throws(() => check(out, VERSION), refusal("not the signature of app.json"));
  });

  it("are refused when app.json is signed by another key than the one it names", () => {
    const { out, manifest, write } = release();
    write.manifest(manifest, newKey().privateKey);
    assert.throws(() => check(out, VERSION), refusal("not the signature of app.json"));
  });

  it("are refused when the signature is not written as it should be", () => {
    for (const text of ["", "nonsense\n", "ed25519:AAAA\n", `rsa:${"A".repeat(88)}\n`]) {
      const { out } = release();
      writeFileSync(join(out, "app.json.sig"), text);
      assert.throws(() => check(out, VERSION), refusal("app.json.sig is not one line"));
    }
  });

  it("are refused when app.json is not JSON or has no key", () => {
    const first = release();
    writeFileSync(join(first.out, "app.json"), "not json");
    assert.throws(() => check(first.out, VERSION), refusal("is not JSON"));
    const second = release();
    const { key: _, ...withoutKey } = second.manifest;
    second.write.manifest(withoutKey);
    assert.throws(() => check(second.out, VERSION), refusal("does not name an ed25519 key"));
  });

  it("are refused when app.json is of another app, another version or other targets", () => {
    let made = release();
    made.write.manifest({ ...made.manifest, name: "another" });
    assert.throws(() => check(made.out, VERSION), refusal(`is of "another"`));

    made = release();
    made.write.manifest({ ...made.manifest, version: "0.5.1" });
    assert.throws(() => check(made.out, VERSION), refusal("is of version 0.5.1"));

    made = release();
    const { [TARGETS[2]]: _, ...two } = made.manifest.files;
    made.write.manifest({ ...made.manifest, files: two });
    assert.throws(() => check(made.out, VERSION), refusal("exactly the three targets"));

    made = release();
    made.write.manifest({
      ...made.manifest,
      files: {
        ...made.manifest.files,
        [TARGETS[0]]: { ...made.manifest.files[TARGETS[0]], url: "https://example.com/elsewhere" },
      },
    });
    assert.throws(() => check(made.out, VERSION), refusal(`does not end in ${fileOf(VERSION, TARGETS[0])}`));
  });

  it("take an executable that says its name and version, and refuse one that says another", () => {
    const own = ownTarget();
    if (own === undefined) return;
    const { out, manifest, sums, write } = release();
    const name = fileOf(VERSION, own);
    // The file, and the sums and the app.json that say it, as `make sums` writes them again.
    const says = (text) => {
      const bytes = `#!/bin/sh\necho ${text}\n`;
      writeFileSync(join(out, name), bytes);
      sums.set(name, sha256(bytes));
      write.sums();
      write.manifest({ ...manifest, files: { ...manifest.files, [own]: { ...manifest.files[own], sha256: sha256(bytes) } } });
    };
    says(`sqlpen ${VERSION}`);
    assert.equal(check(out, VERSION).length, 6);
    says("sqlpen 0.5.1");
    assert.throws(() => check(out, VERSION), refusal(`${name} says it is sqlpen 0.5.1`));
  });

  it("are refused when they are of another version than the one released", () => {
    const { out } = release("0.5.1");
    assert.throws(() => check(out, VERSION), refusal("dist/release holds"));
  });

  it("are refused when they are signed with another key than bateri's, however well", () => {
    const { out } = release();
    // Signed, and the signature holds for the key it names — a key made for a test, not bateri's.
    assert.throws(() => releaseFiles(out, VERSION), refusal(`not with the key bateri takes sqlpen by (${BATERI_KEY})`));
  });

  it("are refused when app.json names the key bateri takes but is signed by another", () => {
    const { out, manifest, write } = release();
    // The key's text alone is not enough: the signature has to be by that key.
    write.manifest({ ...manifest, key: BATERI_KEY });
    assert.throws(() => releaseFiles(out, VERSION), refusal("not the signature of app.json"));
  });

  it("are refused when there is no dist/release", () => {
    assert.throws(() => check(join(tmpdir(), "sqlpen-release-nothing-here"), VERSION), refusal("no dist/release"));
  });
});
