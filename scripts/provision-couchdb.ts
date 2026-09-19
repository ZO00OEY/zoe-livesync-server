// CouchDB provisioning compatible with the third-party Self-hosted LiveSync plugin.
// Keep these package versions aligned with the pinned upstream implementation.
import { checkRemoteVersion } from "npm:@vrtmrz/livesync-commonlib@0.1.0-rc.4/compat/pouchdb/negotiation";
import { PouchDB } from "npm:@vrtmrz/livesync-commonlib@0.1.0-rc.4/compat/pouchdb/pouchdb-browser";

const hostname = required("hostname").replace(/\/+$/, "");
const username = required("username");
const password = required("password");
const database = required("database");
const node = encodeURIComponent(Deno.env.get("node")?.trim() || "_local");
const origins =
  Deno.env.get("origins")?.trim() ||
  "app://obsidian.md,capacitor://localhost,http://localhost";
const retryCount = positiveInteger("retry_count", 12);
const retryDelayMs = nonNegativeInteger("retry_delay_ms", 5_000);

if (!/^[a-z][a-z0-9_$()+-]*$/.test(database)) {
  throw new Error("Invalid CouchDB database name");
}

function required(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function positiveInteger(name: string, fallback: number): number {
  const value = Deno.env.get(name)?.trim();
  if (!value) return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new Error(`${name} must be a positive integer`);
  }
  return parsed;
}

function nonNegativeInteger(name: string, fallback: number): number {
  const value = Deno.env.get(name)?.trim();
  if (!value) return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new Error(`${name} must be a non-negative integer`);
  }
  return parsed;
}

const headers = {
  "Content-Type": "application/json",
  Authorization: `Basic ${btoa(`${username}:${password}`)}`,
};

async function request(
  label: string,
  path: string,
  init: RequestInit,
  accept: (response: Response, body: string) => boolean = (response) =>
    response.ok,
): Promise<void> {
  let lastError: Error | undefined;
  for (let attempt = 1; attempt <= retryCount; attempt++) {
    try {
      const response = await fetch(`${hostname}${path}`, init);
      const body = await response.text();
      if (accept(response, body)) return;
      lastError = new Error(
        `${label} failed with HTTP ${response.status}: ${body}`,
      );
      if (response.status < 500) throw lastError;
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      if (/failed with HTTP 4/.test(lastError.message)) throw lastError;
    }
    if (attempt < retryCount) {
      await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
    }
  }
  throw lastError || new Error(`${label} failed after ${retryCount} attempts`);
}

await request(
  "single-node cluster setup",
  "/_cluster_setup",
  {
    method: "POST",
    headers,
    body: JSON.stringify({
      action: "enable_single_node",
      username,
      password,
      bind_address: "0.0.0.0",
      port: 5984,
      singlenode: true,
    }),
  },
  (response, body) =>
    response.ok ||
    ((response.status === 400 || response.status === 409) &&
      /already|finished/i.test(body)),
);

const settings: Array<[string, string, string]> = [
  ["require authenticated users", "chttpd/require_valid_user", '"true"'],
  [
    "require authenticated users for auth",
    "chttpd_auth/require_valid_user",
    '"true"',
  ],
  [
    "set authentication challenge",
    "httpd/WWW-Authenticate",
    '"Basic realm=\\"couchdb\\""',
  ],
  ["enable HTTP CORS", "httpd/enable_cors", '"true"'],
  ["enable clustered HTTP CORS", "chttpd/enable_cors", '"true"'],
  ["set maximum request size", "chttpd/max_http_request_size", '"4294967296"'],
  ["set maximum document size", "couchdb/max_document_size", '"50000000"'],
  ["enable CORS credentials", "cors/credentials", '"true"'],
  ["set allowed CORS origins", "cors/origins", JSON.stringify(origins)],
];

for (const [label, key, body] of settings) {
  await request(label, `/_node/${node}/_config/${key}`, {
    method: "PUT",
    headers,
    body,
  });
}

const databasePath = `/${encodeURIComponent(database)}`;
await request(
  "create database",
  databasePath,
  { method: "PUT", headers },
  (response) => response.ok || response.status === 412,
);

const remote = new PouchDB(`${hostname}${databasePath}`, {
  adapter: "http",
  auth: { username, password },
  skip_setup: true,
});
try {
  const compatible = await checkRemoteVersion(remote, async () => false);
  if (!compatible) {
    throw new Error(
      "Remote database uses an incompatible LiveSync database version",
    );
  }
} finally {
  await remote.close();
}

console.log(
  "CouchDB provisioning and LiveSync database-version verification completed.",
);
