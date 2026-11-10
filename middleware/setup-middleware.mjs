// setup-middleware.mjs — owner-run middleware setup, API route.
//
// Why this exists (2026-11-10): wrangler does not run correctly in the
// owner's Termux (npx installs prompt in a loop and invocations exit
// silently; no global binary survives). The Cloudflare API token itself
// verified ACTIVE via /user/tokens/verify. This script performs the same
// Phase 0 steps as the wrangler version — D1 ledger database + schema,
// Worker deploy with the D1 binding, bearer secret — by speaking to the
// Cloudflare API directly, the same pattern as the fleet's earlier
// owner-run deposit scripts. Node 18+ built-ins only; no dependencies.
//
// Auth: reads CLOUDFLARE_API_TOKEN from the environment (the owner
// exports it in the session, e.g. from a local file). The token value is
// never printed. The middleware bearer token is read with a muted prompt
// and likewise never printed.

import { readFileSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import readline from "node:readline";

const API = "https://api.cloudflare.com/client/v4";
const WORKER_NAME = "andrew-middleware";
const DB_NAME = "middleware-ledger";
const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS ledger (
     request_id TEXT PRIMARY KEY,
     status TEXT NOT NULL,
     response_json TEXT,
     created_at DATETIME DEFAULT CURRENT_TIMESTAMP
   )`,
  `CREATE TABLE IF NOT EXISTS audit (
     audit_id TEXT PRIMARY KEY,
     request_id TEXT NOT NULL,
     caller TEXT NOT NULL,
     action TEXT NOT NULL,
     reason TEXT,
     created_at DATETIME DEFAULT CURRENT_TIMESTAMP
   )`,
  `CREATE TABLE IF NOT EXISTS previews (
     preview_id TEXT PRIMARY KEY,
     action TEXT NOT NULL,
     payload_json TEXT NOT NULL,
     expires_at DATETIME NOT NULL
   )`,
];

const token = process.env.CLOUDFLARE_API_TOKEN;
if (!token) {
  console.error("CLOUDFLARE_API_TOKEN is not set in this session. Export it first and rerun.");
  process.exit(1);
}

async function cf(path, init = {}) {
  const res = await fetch(API + path, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, ...(init.headers || {}) },
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || data.success === false) {
    const msg = (data.errors || []).map((e) => `${e.code}: ${e.message}`).join("; ") || `HTTP ${res.status}`;
    throw new Error(`${path} -> ${msg}`);
  }
  return data.result;
}

function ask(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) =>
    rl.question(question, (a) => {
      rl.close();
      resolve(a.trim());
    })
  );
}

function askHidden(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(question, (a) => {
      rl.close();
      process.stdout.write("\n");
      resolve(a.trim());
    });
    rl._writeToOutput = () => {};
  });
}

console.log("=== Middleware Phase 0: Infrastructure Setup (API route) ===");

// 1. Verify the token and identify the account.
const verification = await cf("/user/tokens/verify");
console.log(`[OK] Token status: ${verification.status}`);
const accounts = await cf("/accounts");
if (!accounts.length) throw new Error("No Cloudflare accounts visible to this token.");
const account = accounts[0];
console.log(`[OK] Account: ${account.name} (${account.id})`);

// 2. D1 database: create if absent, then apply the schema.
let dbs = await cf(`/accounts/${account.id}/d1/database?name=${DB_NAME}`);
let db = dbs[0];
if (!db) {
  console.log(`Creating D1 database '${DB_NAME}'...`);
  db = await cf(`/accounts/${account.id}/d1/database`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: DB_NAME }),
  });
  console.log(`[OK] Created D1 database ${db.uuid}`);
} else {
  console.log(`[OK] D1 database '${DB_NAME}' already exists (${db.uuid}).`);
}
for (const sql of SCHEMA) {
  await cf(`/accounts/${account.id}/d1/database/${db.uuid}/query`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ sql }),
  });
}
console.log("[OK] Schema applied (ledger, audit, previews).");

// 3. Deploy the Worker with its D1 binding.
const proceed = (await ask("Deploy the Worker now? (y/n) ")).toLowerCase();
if (proceed !== "y") {
  console.log("Deploy skipped by owner. Infrastructure is ready; rerun to deploy.");
  process.exit(0);
}
const scriptDir = dirname(fileURLToPath(import.meta.url));
const code = readFileSync(`${scriptDir}/src/index.js`, "utf8");
const metadata = {
  main_module: "index.js",
  compatibility_date: "2024-11-01",
  bindings: [{ name: "DB", type: "d1", id: db.uuid }],
};
const form = new FormData();
form.append("metadata", new Blob([JSON.stringify(metadata)], { type: "application/json" }));
form.append("index.js", new Blob([code], { type: "application/javascript+module" }), "index.js");
await cf(`/accounts/${account.id}/workers/scripts/${WORKER_NAME}`, { method: "PUT", body: form });
console.log("[OK] Worker deployed.");

// Enable the workers.dev subdomain so the health check is reachable.
await cf(`/accounts/${account.id}/workers/scripts/${WORKER_NAME}/subdomain`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ enabled: true }),
});
const sub = await cf(`/accounts/${account.id}/workers/subdomain`);
const url = `https://${WORKER_NAME}.${sub.subdomain}.workers.dev`;
console.log(`[OK] workers.dev enabled: ${url}`);

// 4. Bearer secret for Muse -> Worker authentication.
const setSecret = (await ask("Set MUSE_BEARER_TOKEN now? (y/n) ")).toLowerCase();
if (setSecret === "y") {
  const value = await askHidden("Paste the bearer token (input hidden), then Enter: ");
  if (value) {
    await cf(`/accounts/${account.id}/workers/scripts/${WORKER_NAME}/secrets`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: "MUSE_BEARER_TOKEN", text: value, type: "secret_text" }),
    });
    console.log("[OK] MUSE_BEARER_TOKEN set.");
  } else {
    console.log("[skip] Empty value; secret not set.");
  }
} else {
  console.log("[skip] MUSE_BEARER_TOKEN not set (the Worker will answer 401 until it is).");
}

console.log("");
console.log("=== SETUP COMPLETE ===");
console.log(`Health check: ${url}/v1/health`);
console.log("Remaining by design: GCP_WORKSPACE_SA_KEY and WORKSPACE_ADMIN_EMAIL are NOT set —");
console.log("the Groups service account is a separate, later step.");
console.log("You can now revoke the Cloudflare API token you used for this run.");
