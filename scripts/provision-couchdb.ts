import { provisionCouchDB } from "https://raw.githubusercontent.com/vrtmrz/obsidian-livesync/2c2b9c90e4e10a454f2838c63ba656c0e67a374c/utils/couchdb/provision.ts";

const optionalNumber = (name: string) => {
  const value = Deno.env.get(name)?.trim();
  return value ? Number(value) : undefined;
};

await provisionCouchDB({
  hostname: Deno.env.get("hostname") ?? "",
  username: Deno.env.get("username") ?? "",
  password: Deno.env.get("password") ?? "",
  node: Deno.env.get("node"),
  database: Deno.env.get("database"),
  origins: Deno.env.get("origins"),
  retryCount: optionalNumber("retry_count"),
  retryDelayMs: optionalNumber("retry_delay_ms"),
});

console.log("CouchDB provisioning completed.");
