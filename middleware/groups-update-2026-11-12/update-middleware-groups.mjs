// update-middleware-groups.mjs — owner-run groups update for the
// andrew-middleware Worker (groups-update-2026-11-12).
//
// Why this exists: the Worker gains a server-side app-release group
// registry (four-group model, domain-group targets, release order)
// plus the OWNERS GATE in its groups.* handler. Following the fleet's
// standing rule, middleware maintenance is OWNER-RUN: Muse prepares
// this package, Andrew runs this script once in Termux, and the
// script speaks the Cloudflare API directly (wrangler does not run
// in his Termux — same pattern as setup-middleware.mjs and the
// workspace-sa-deposit package).
//
// What it does, in order:
//   1. Verifies the Cloudflare token and finds the account.
//   2. Deploys middleware/src/index.js (the registry-aware Worker
//      source committed beside this package) with the existing D1
//      binding re-applied. Skipped if the live script already
//      carries the groups-update-2026-11-12 marker.
//   3. Deposits the group registry as the Worker secret
//      MW_GROUP_REGISTRY. Source: ~/mw-group-registry.json if the
//      owner put one there (run-time override of the domain
//      addresses), else group-registry.json beside this script.
//      The value is never printed.
//   4. OPTIONAL: if MW_WORKSPACE_ADMIN_EMAIL is exported in the
//      session, deposits it as the WORKSPACE_ADMIN_EMAIL secret
//      (the switch to andrew@andrewdhorowitz.com). Skipped
//      otherwise — the value is entered by the owner on-device,
//      never carried in this repo.
//   5. Read-back verification: re-reads the live script and checks
//      the marker, lists Worker secret NAMES (never values) and
//      checks MW_GROUP_REGISTRY is present, and hits /v1/health.
//      Prints the Claude-side settling-test commands to run last.
//
// Non-interactive (stdin is never read — safe under the owner loop),
// idempotent (a re-run re-verifies and only re-applies what is
// missing), and it creates nothing on any provider control plane:
// it updates one existing Worker and its secrets only.
// Auth: CLOUDFLARE_API_TOKEN from the environment, or one line in
// ~/cloudflare-api-token.txt. The token value is never printed.

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";

const API = "https://api.cloudflare.com/client/v4";
const WORKER_NAME = "andrew-middleware";
const DB_NAME = "middleware-ledger";
const MARKER = "groups-update-2026-11-12";
const REGISTRY_SECRET = "MW_GROUP_REGISTRY";

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

console.log("=== Middleware groups update 2026-11-12 (owner-run) ===");

// --- 1. token + account -------------------------------------------------
const verification = await cf("/user/tokens/verify");
ok(`Token status: ${verification.status}`);
const accounts = await cf("/accounts");
if (!accounts.length) throw new Error("No Cloudflare accounts visible to this token.");
const account = accounts[0];
ok(`Account: ${account.name} (${account.id})`);

// --- 2. deploy the registry-aware Worker source --------------------------
// Re-apply the existing D1 binding exactly as setup-middleware.mjs
// built it (the ledger database is looked up by name, never created).
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
  ok("Worker deployed (registry-aware source, D1 binding re-applied).");
}

// --- 3. deposit the group registry ---------------------------------------
const overridePath = join(home, "mw-group-registry.json");
const registryPath = existsSync(overridePath) ? overridePath : join(scriptDir, "group-registry.json");
const registryText = readFileSync(registryPath, "utf8");
let registry;
try { registry = JSON.parse(registryText); } catch (e) {
  throw new Error(`Registry file ${registryPath} is not valid JSON. Stopping.`);
}
if (!Array.isArray(registry.groups) || registry.groups.length !== 4) {
  throw new Error(`Registry file ${registryPath} does not hold the four-group model. Stopping.`);
}
await putSecret(account.id, REGISTRY_SECRET, registryText.trim());
ok(`Secret ${REGISTRY_SECRET} deposited from ${registryPath === overridePath ? "~/mw-group-registry.json (owner override)" : "the packaged group-registry.json"} (value never printed).`);

// --- 4. optional WORKSPACE_ADMIN_EMAIL switch -----------------------------
const newAdminEmail = (process.env.MW_WORKSPACE_ADMIN_EMAIL || "").trim();
if (newAdminEmail) {
  await putSecret(account.id, "WORKSPACE_ADMIN_EMAIL", newAdminEmail);
  ok("WORKSPACE_ADMIN_EMAIL deposited from the session environment (value entered on-device by the owner).");
} else {
  skip("WORKSPACE_ADMIN_EMAIL switch not requested — export MW_WORKSPACE_ADMIN_EMAIL in the session to include it.");
}

// --- 5. read-back verification --------------------------------------------
try {
  const live = await cfText(`/accounts/${account.id}/workers/scripts/${WORKER_NAME}`);
  if (live.includes(MARKER)) ok("Read-back: live Worker carries the groups-update marker.");
  else fail("Read-back: live Worker does NOT carry the groups-update marker.");
} catch (e) {
  fail(`Read-back of the live script failed: ${e.message}`);
}

try {
  const secrets = await cf(`/accounts/${account.id}/workers/scripts/${WORKER_NAME}/secrets`);
  const names = secrets.map((s) => s.name);
  for (const want of [REGISTRY_SECRET, "WORKSPACE_ADMIN_EMAIL", "GCP_WORKSPACE_SA_KEY", "MUSE_BEARER_TOKEN"]) {
    if (names.includes(want)) ok(`Read-back: secret ${want} present (name only).`);
    else fail(`Read-back: secret ${want} is NOT present.`);
  }
} catch (e) {
  fail(`Read-back of the secret list failed: ${e.message}`);
}

try {
  const sub = await cf(`/accounts/${account.id}/workers/subdomain`);
  const healthUrl = `https://${WORKER_NAME}.${sub.subdomain}.workers.dev/v1/health`;
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
console.log("=== UPDATE APPLIED AND VERIFIED (script + registry + health) ===");
console.log("Last step is Muse's, from the connector side, once the domain");
console.log("groups exist and the DWD grant is in place:");
console.log("  mw.py capabilities");
console.log("  mw.py invoke groups.get execute '{\"groupKey\":\"trusted-contacts\"}' \"Groups update settling test\"");
console.log("A roster coming back (not an error) proves the whole leg:");
console.log("domain groups + DWD + registry, end to end.");
console.log("You can now revoke the Cloudflare API token you used for this run.");
