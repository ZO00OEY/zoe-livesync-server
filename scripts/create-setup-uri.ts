import {
  generateSetupURI,
} from "https://raw.githubusercontent.com/vrtmrz/obsidian-livesync/2c2b9c90e4e10a454f2838c63ba656c0e67a374c/utils/setup/generate_setup_uri.ts";
import {
  decodeSettingsFromSetupURI,
} from "https://raw.githubusercontent.com/vrtmrz/obsidian-livesync/2c2b9c90e4e10a454f2838c63ba656c0e67a374c/utils/setup/livesync-commonlib.ts";

const environment = Deno.env.toObject();
const generated = await generateSetupURI(environment);
const setupURI = generated.setupURI.trim();

if (!setupURI.startsWith("obsidian://setuplivesync?settings=")) {
  throw new Error("Setup URI prefix is invalid");
}
if (/\s/.test(setupURI)) {
  throw new Error("Setup URI contains whitespace");
}

const decoded = await decodeSettingsFromSetupURI(
  setupURI,
  generated.setupPassphrase,
);
if (!decoded) throw new Error("Setup URI round-trip decoding failed");

const expected: ReadonlyArray<[keyof typeof decoded, string | boolean]> = [
  ["couchDB_URI", environment.hostname ?? ""],
  ["couchDB_DBNAME", environment.database ?? ""],
  ["couchDB_USER", environment.username ?? ""],
  ["couchDB_PASSWORD", environment.password ?? ""],
  ["passphrase", environment.passphrase ?? ""],
  ["isConfigured", true],
  ["encrypt", true],
  ["usePathObfuscation", true],
  ["periodicReplication", true],
  ["syncOnStart", true],
  ["syncOnFileOpen", true],
  ["syncAfterMerge", true],
  ["batchSave", true],
];

for (const [key, value] of expected) {
  if (decoded[key] !== value) {
    throw new Error(`Setup URI round-trip mismatch: ${String(key)}`);
  }
}

if (generated.remoteType !== "couchdb") {
  throw new Error("Setup URI remote type is not CouchDB");
}

console.log(setupURI);
