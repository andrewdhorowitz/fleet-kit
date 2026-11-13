// update-middleware-home.mjs — owner-run named-automations update
// for the andrew-middleware Worker (home-update-2026-11-13).
//
// Why this exists: the Worker becomes the linked Smart Home
// service for Andrew's named automations (spec:
// named-automations-spec-2026-11-13.md, approved Nov 13, 2026) —
// /home/auth + /home/token + /home/fulfill routes, a D1 registry
// of named automations, the home.automations.* actions with the
// §4 pulse protocol and §5 honesty contract — and, as a separate
// change set in the same source, the long-filed error-response
// fix (pre-envelope errors return proper HTTP Responses instead
// of bare objects that surfaced as HTTP 500). Following the
// fleet's standing rule, middleware maintenance is OWNER-RUN:
// Muse prepares this package, Andrew runs this script once in
// Termux, and the script speaks the Cloudflare API directly
// (wrangler does not run in his Termux — same pattern as
// setup-middleware.mjs and the groups update).
//
// What it does, in order:
//   1. Verifies the Cloudflare token and finds the account.
//   2. Deploys middleware/src/index.js with the existing D1
//      binding re-applied. Skipped if the live script already
//      carries the home-update-2026-11-13 marker.
//   3. Applies the home schema (home_automations, home_links,
//      home_tokens, home_pulses — CREATE TABLE IF NOT EXISTS) to
//      the existing middleware-ledger D1 database.
//   4. OPTIONAL: if MW_HOME_LINK_CODE is exported in the session,
//      deposits it as the HOME_LINK_CODE Worker secret (the link
//      code Andrew invents; entered on-device only, never printed,
//      never carried in this repo). Skipped otherwise.
//   5. Read-back verification: re-reads the live script and checks
//      the marker; lists Worker secret NAMES (never values) and
//      checks MUSE_BEARER_TOKEN, GOOGLE_HOME_SA_JSON and
//      HOME_LINK_CODE; hits /v1/health.
//      FAIL-SAFE: if GOOGLE_HOME_SA_JSON is absent, this script
//      reports the update INCOMPLETE and prints the separate
//      owner deposit step. The script NEVER accepts, prints, or
//      routes that value — presence check only.
//   6. Prints the remaining owner steps (Actions console) and the
//      Claude-side settling tests.
//
// Non-interactive (stdin is never read — safe under the owner
// loop), idempotent (a re-run re-verifies and only re-applies
// what is missing), and it creates nothing on any provider
// control plane: it updates one existing Worker, its secrets,
// and its existing D1 database schema.
// Auth: CLOUDFLARE_API_TOKEN from the environment, or one line in
// ~/cloudflare-api-token.txt. The token value is never printed.

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";

const API = "https://api.cloudflare.com/client/v4";
const WORKER_NAME = "andrew-middleware";
const DB_NAME = "middleware-ledger";
const MARKER = "home-update-2026-11-13";
const SA_SECRET = "GOOGLE_HOME_SA_JSON";
const LINK_CODE_SECRET = "HOME_LINK_CODE";

const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS home_automations (
     slug TEXT PRIMARY KEY,
     device_id TEXT NOT NULL,
     display_name TEXT NOT NULL,
     active INTEGER NOT NULL DEFAULT 0,
     cooldown_seconds INTEGER NOT NULL DEFAULT 10,
     known_state TEXT NOT NULL DEFAULT 'unknown',
     last_pulse_at TEXT,
     updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
   )`,
  `CREATE TABLE IF NOT EXISTS home_links (
     agent_user_id TEXT PRIMARY KEY,
     linked_at TEXT,
     disconnected_at TEXT,
     updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
   )`,
  `CREATE TABLE IF NOT EXISTS home_tokens (
     token_hash TEXT PRIMARY KEY,
     kind TEXT NOT NULL,
     agent_user_id TEXT NOT NULL,
     redirect_uri TEXT,
     created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
     expires_at TEXT
   )`,
  `CREATE TABLE IF NOT EXISTS home_pulses (
     pulse_key TEXT PRIMARY KEY,
     slug TEXT NOT NULL,
     request_id TEXT,
     outcome TEXT NOT NULL,
     detail TEXT,
     result_json TEXT,
     http_status INTEGER,
     created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
   )`,
];

const scriptDir = dirname(fileURLToPath(import.meta.url));
const home = homedir();

let failed = false;
const ok = (m) => console.log(`✓ ${m}`);
const already = (m) => console.log(`✓ already — ${m}`);
const skip = (m) => console.log(`– skipped (${m})`);
const fail = (m) => { failed = true; console.log(`✗ ${m}`); };

// --- token ------------------------------------------------------------
let token = process.env.CLOUDFLARE_API_TOKEN || "";
if (!token) {
  const tokenFile = join(home, "cloudflare-api-token.txt");
  if (existsSync(tokenFile)) token = readFileSync(tokenFile, "utf8").trim();
}
if (!token) {
  console.error("No Cloudflare API token: export CLOUDFLARE_API_TOKEN or put one line in ~/cloudflare-api-token.txt, then rerun.");
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

async function cfText(path) {
  const res = await fetch(API + path, { headers: { Authorization: `Bearer ${token}` } });
  if (!res.ok) throw new Error(`${path} -> HTTP ${res.status}`);
  return res.text();
}

async function putSecret(accountId, name, text) {
  await cf(`/accounts/${accountId}/workers/scripts/${WORKER_NAME}/secrets`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name, text, type: "secret_text" }),
  });
}

console.log("=== Middleware home update 2026-11-13 (owner-run) ===");

// --- 1. token + account -------------------------------------------------
const verification = await cf("/user/tokens/verify");
ok(`Token status: ${verification.status}`);
const accounts = await cf("/accounts");
if (!accounts.length) throw new Error("No Cloudflare accounts visible to this token.");
const account = accounts[0];
ok(`Account: ${account.name} (${account.id})`);

// --- 2. deploy the home-aware Worker source ------------------------------
const dbs = await cf(`/accounts/${account.id}/d1/database?name=${DB_NAME}`);
const db = dbs[0];
if (!db) throw new Error(`D1 database '${DB_NAME}' not found — run setup-middleware.mjs first.`);
ok(`D1 database '${DB_NAME}' found (${db.uuid}).`);

let liveHasMarker = false;
try {
  const live = await cfText(`/accounts/${account.id}/workers/scripts/${WORKER_NAME}`);
  liveHasMarker = live.includes(MARKER);
} catch (e) {
  fail(`Could not read the live Worker script: ${e.message}`);
}

if (liveHasMarker) {
  already(`live Worker already carries the ${MARKER} marker — deploy skipped.`);
} else {
  const sourcePath = join(scriptDir, "..", "src", "index.js");
  const code = readFileSync(sourcePath, "utf8");
  if (!code.includes(MARKER)) throw new Error(`Local source ${sourcePath} does not carry the ${MARKER} marker — is the fleet-kit checkout up to date? Stopping.`);
  const metadata = {
    main_module: "index.js",
    compatibility_date: "2024-11-01",
    bindings: [{ name: "DB", type: "d1", id: db.uuid }],
  };
  const form = new FormData();
  form.append("metadata", new Blob([JSON.stringify(metadata)], { type: "application/json" }));
  form.append("index.js", new Blob([code], { type: "application/javascript+module" }), "index.js");
  await cf(`/accounts/${account.id}/workers/scripts/${WORKER_NAME}`, { method: "PUT", body: form });
  ok("Worker deployed (home-aware source, D1 binding re-applied).");
}

// --- 3. apply the home schema ---------------------------------------------
for (const sql of SCHEMA) {
  await cf(`/accounts/${account.id}/d1/database/${db.uuid}/query`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ sql }),
  });
}
ok("Home schema applied (home_automations, home_links, home_tokens, home_pulses).");

// --- 4. optional HOME_LINK_CODE deposit ------------------------------------
const linkCode = (process.env.MW_HOME_LINK_CODE || "").trim();
if (linkCode) {
  await putSecret(account.id, LINK_CODE_SECRET, linkCode);
  ok(`${LINK_CODE_SECRET} deposited from the session environment (value entered on-device by the owner, never printed).`);
} else {
  skip(`${LINK_CODE_SECRET} deposit not requested — export MW_HOME_LINK_CODE in the session to include it, or add it in the dashboard.`);
}

// --- 5. read-back verification ----------------------------------------------
try {
  const live = await cfText(`/accounts/${account.id}/workers/scripts/${WORKER_NAME}`);
  if (live.includes(MARKER)) ok("Read-back: live Worker carries the home-update marker.");
  else fail("Read-back: live Worker does NOT carry the home-update marker.");
} catch (e) {
  fail(`Read-back of the live script failed: ${e.message}`);
}

let workerBase = "";
try {
  const sub = await cf(`/accounts/${account.id}/workers/subdomain`);
  workerBase = `https://${WORKER_NAME}.${sub.subdomain}.workers.dev`;
} catch (e) {
  fail(`Could not read the workers.dev subdomain: ${e.message}`);
}

try {
  const secrets = await cf(`/accounts/${account.id}/workers/scripts/${WORKER_NAME}/secrets`);
  const names = secrets.map((s) => s.name);
  if (names.includes("MUSE_BEARER_TOKEN")) ok("Read-back: secret MUSE_BEARER_TOKEN present (name only).");
  else fail("Read-back: secret MUSE_BEARER_TOKEN is NOT present — the invoke API cannot authenticate.");
  if (names.includes(LINK_CODE_SECRET)) {
    ok(`Read-back: secret ${LINK_CODE_SECRET} present (name only) — account linking is gated and ready.`);
  } else {
    fail(`Read-back: secret ${LINK_CODE_SECRET} is NOT present — linking stays disabled until it is set.`);
    console.log(`    OWNER STEP: invent a link code (a passphrase only you know) and either`);
    console.log(`    re-run this script with it exported —  export MW_HOME_LINK_CODE=<your code>`);
    console.log(`    — or add a secret named ${LINK_CODE_SECRET} to the ${WORKER_NAME} Worker`);
    console.log(`    in the Cloudflare dashboard. Never send the code through chat.`);
  }
  if (names.includes(SA_SECRET)) {
    ok(`Read-back: secret ${SA_SECRET} present (name only) — Home Graph reporting is credentialed.`);
  } else {
    fail(`Read-back: secret ${SA_SECRET} is NOT present on this Worker — pulses cannot report state without it.`);
    console.log(`    OWNER STEP (separate deposit — this script never handles the value):`);
    console.log(`    the Home Graph service-account JSON already exists as a secret on the`);
    console.log(`    text-bridge Worker. Deposit the same JSON as a secret named`);
    console.log(`    ${SA_SECRET} on the ${WORKER_NAME} Worker, using the Cloudflare`);
    console.log(`    dashboard (Workers & Pages → ${WORKER_NAME} → Settings → Variables`);
    console.log(`    and Secrets → Add → Secret) with the file's contents read on your`);
    console.log(`    own device. Never paste it into chat or hand it to Muse.`);
    console.log(`    Then re-run this script — it will verify presence and finish.`);
  }
} catch (e) {
  fail(`Read-back of the secret list failed: ${e.message}`);
}

try {
  const healthUrl = `${workerBase}/v1/health`;
  const res = await fetch(healthUrl);
  const body = await res.text();
  if (res.ok && body.includes('"ok"')) ok(`Health check passed: ${healthUrl}`);
  else fail(`Health check unexpected: HTTP ${res.status} from ${healthUrl}`);
} catch (e) {
  fail(`Health check failed: ${e.message}`);
}

console.log("");
if (failed) {
  console.log("=== UPDATE INCOMPLETE — see ✗ lines above; nothing was rolled back, re-running is safe. ===");
  process.exit(1);
}
console.log("=== UPDATE APPLIED AND VERIFIED (script + schema + secrets + health) ===");
console.log("");
console.log("Remaining owner steps, in order:");
console.log("  1. Actions console (Google Cloud project family-routines-app, the");
console.log("     same project as the prototype link): create the Smart Home");
console.log("     action for the middleware service. The service DISPLAY NAME is");
console.log("     yours to settle (spec §9b — it and the devices carry your name);");
console.log("     this package deliberately uses a placeholder.");
console.log(`  2. Fulfillment URL:  ${workerBase}/home/fulfill`);
console.log(`     Account linking authorization URL:  ${workerBase}/home/auth`);
console.log(`     Account linking token URL:          ${workerBase}/home/token`);
console.log("     OAuth client ID / secret in the console: any values — the");
console.log("     Worker ignores them; the link code is the gate.");
console.log("     Cloud fulfillment + local fulfillment off; account linking");
console.log("     type: OAuth / Authorization Code.");
console.log("  3. Release the action to Test, then link it in Google Home");
console.log("     (enter the link code on the /home/auth page).");
console.log("  4. Tell Muse the first automation name once it exists in");
console.log("     Google Home — Muse seeds the registry entry, you enable it.");
console.log("");
console.log("Muse's settling tests after that, from the connector side:");
console.log("  mw.py capabilities");
console.log("  mw.py invoke home.automations.list execute '{}' \"Named automations settling test\"");
console.log("You can now revoke the Cloudflare API token you used for this run.");
