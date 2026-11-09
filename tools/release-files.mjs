// The files of a release, and what makes them one: the three executables, the SHA256SUMS that
// names them, and the signed app.json that a terminal following sqlpen reads (pencere's
// `apps.md`). `tools/release.mjs` asks for them before it tags and before it publishes; the
// tests ask the same, of a directory of their own.

import { execFileSync } from "node:child_process";
import { createHash, createPublicKey, verify } from "node:crypto";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

export const NAME = "sqlpen";

/** The systems sqlpen is built for (the Makefile's TARGETS), each on a machine of its own. */
export const TARGETS = ["aarch64-apple-darwin", "aarch64-unknown-linux-musl", "x86_64-unknown-linux-musl"];

export class Refusal extends Error {}
export const refuse = (what) => {
  throw new Refusal(what);
};

/**
 * The key bateri takes sqlpen's releases by without asking: the public half of the "bateri"
 * signing key (`ed25519:` and the 32 bytes in base64). A release signed with any other key is one
 * every bateri turns away with "Signed with another key", and a published release cannot be
 * taken back, so it is refused here, before it is tagged or published.
 */
export const BATERI_KEY = "ed25519:59e8IXkv6FP4tD4uJ/fvw9/pSV+1YgEpXtXQzWLwOpU=";

/** The executable of a release for a target. */
export const fileOf = (version, target) => `${NAME}-${version}-${target}`;

/** The target of the machine this runs on, for the one executable it can run. */
export function ownTarget() {
  const arch = { arm64: "aarch64", x64: "x86_64" }[process.arch];
  if (arch === undefined) return undefined;
  if (process.platform === "darwin") return `${arch}-apple-darwin`;
  if (process.platform === "linux") return `${arch}-unknown-linux-musl`;
  return undefined;
}

/** What precedes the 32 bytes of an Ed25519 public key in its DER form (RFC 8410). */
const SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

/** The bytes of `ed25519:<base64>`: 32 for a key, 64 for a signature; `undefined` if it is not one. */
function ed25519Bytes(text, length) {
  if (!text.startsWith("ed25519:")) return undefined;
  const coded = text.slice("ed25519:".length);
  const bytes = Buffer.from(coded, "base64");
  return bytes.length === length && bytes.toString("base64") === coded ? bytes : undefined;
}

/**
 * The app.json of a release, read and checked: signed by the key it names (`apps.md` Section 5),
 * and that key is `trust`, of this app and this version, naming exactly the three executables at
 * addresses that end in their names, each with the sum SHA256SUMS lists. `listed` is what
 * SHA256SUMS lists, by name.
 */
function checkManifest(dir, version, listed, trust) {
  const bytes = readFileSync(join(dir, "app.json"));
  const signature = readFileSync(join(dir, "app.json.sig"), "utf8").replace(/\n$/, "");
  let manifest;
  try {
    manifest = JSON.parse(bytes.toString("utf8"));
  } catch {
    refuse("dist/release/app.json is not JSON: make sums again");
  }
  const key = typeof manifest?.key === "string" ? ed25519Bytes(manifest.key, 32) : undefined;
  const sig = ed25519Bytes(signature, 64);
  if (key === undefined) refuse("dist/release/app.json does not name an ed25519 key");
  if (sig === undefined) refuse("dist/release/app.json.sig is not one line of ed25519:<base64>");
  const publicKey = createPublicKey({ key: Buffer.concat([SPKI_PREFIX, key]), format: "der", type: "spki" });
  if (!verify(null, bytes, publicKey, sig)) {
    refuse("dist/release/app.json.sig is not the signature of app.json by the key it names: make sums again");
  }
  if (manifest.key !== trust) {
    refuse(
      `dist/release/app.json is signed with ${manifest.key}, not with the key bateri takes ${NAME} by (${trust}): sign with the "bateri" key (RELEASING.md)`,
    );
  }
  if (manifest.name !== NAME) refuse(`dist/release/app.json is of ${JSON.stringify(manifest.name)}, not ${NAME}`);
  if (manifest.version !== version) {
    refuse(`dist/release/app.json is of version ${manifest.version}, not ${version}: make sums again`);
  }
  const files = manifest.files ?? {};
  if (Object.keys(files).sort().join("\n") !== [...TARGETS].sort().join("\n")) {
    refuse("dist/release/app.json does not name exactly the three targets");
  }
  for (const target of TARGETS) {
    const name = fileOf(version, target);
    if (typeof files[target]?.url !== "string" || !files[target].url.endsWith(`/${name}`)) {
      refuse(`dist/release/app.json: the address of ${target} does not end in ${name}`);
    }
    if (files[target].sha256 !== listed.get(name)) {
      refuse(`dist/release/app.json has another sum for ${name} than SHA256SUMS: make sums again`);
    }
  }
}

/**
 * The files `make dist` and `make sums` made in `dir` for this version: the three executables, the
 * SHA256SUMS that names exactly them, each with the sum it lists, and the app.json and its
 * signature that say the same sums. The names carry the version, so a dist/release made before
 * the version moved is refused; the one executable this machine can run says its version (`<version>`, or `${NAME} <version>` as
 * `--version` of sqlpen does). `trust`
 * is the key the app.json is signed with: bateri's own, which the tests replace with the one of
 * their own.
 */
export function releaseFiles(dir, version, trust = BATERI_KEY) {
  if (!existsSync(dir)) refuse(`no dist/release: make dist, after the release commit`);
  const expected = TARGETS.map((target) => fileOf(version, target));
  const found = readdirSync(dir).sort();
  const wanted = [...expected, "SHA256SUMS", "app.json", "app.json.sig"].sort();
  if (found.join("\n") !== wanted.join("\n")) {
    refuse(
      `dist/release holds ${found.join(", ") || "nothing"} and a release of ${version} is ${wanted.join(", ")}: make dist again, after the release commit, and make sums`,
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
    refuse("dist/release/SHA256SUMS does not name exactly the three executables");
  }
  for (const name of expected) {
    const sum = createHash("sha256")
      .update(readFileSync(join(dir, name)))
      .digest("hex");
    if (listed.get(name) !== sum) refuse(`${name} is not the file SHA256SUMS lists: make dist again`);
  }
  checkManifest(dir, version, listed, trust);
  const own = ownTarget();
  if (own !== undefined) {
    const said = execFileSync(join(dir, fileOf(version, own)), ["--version"], { encoding: "utf8" }).trim();
    if (said !== version && said !== `${NAME} ${version}`) refuse(`${fileOf(version, own)} says it is ${said}: make dist again`);
  }
  return [...expected, "SHA256SUMS", "app.json", "app.json.sig"];
}
