// update-middleware-contact-sensor.mjs — owner-run contact-sensor
// update for the andrew-middleware Worker
// (contact-sensor-update-2026-11-15).
//
// Why: the named-automation virtual device was presented to Google
// Home as a switch (action.devices.types.SWITCH + OnOff trait).
// Google Home does not offer that switch as a starter in its
// automation editor, so no routine could fire from a pulse —
// pulses were accepted by Home Graph all evening Nov 14, 2026 and
// triggered nothing (Andrew confirmed: no starter was pickable).
// Andrew's direction (Nov 15, 2026): present the device as a
// CONTACT SENSOR instead — door/contact devices are offered as
// starters ("when the contact opens"). In cloud-to-cloud terms
// that is type action.devices.types.DOOR + trait
// action.devices.traits.OpenClose with attributes
// { discreteOnlyOpenClose: true, queryOnlyOpenClose: true } —
// Google's trait reference: "Sensors that can only report open
// state should set queryOnlyOpenClose to true." Same registry
// entry, same device id (mw-automation-claude-wake-up-tv); only
// the presentation changes. The pulse now reports openPercent
// 100 (open) -> hold -> 0 (closed); the 10 s hold from
// pulse-hold-update-2026-11-14 rides along in the same source (if
// that package was never run, this deploy brings both changes).
//
// Middleware maintenance is OWNER-RUN by standing rule: Andrew
// runs this once in Termux; it speaks the Cloudflare API directly
// (wrangler does not run in his Termux).
//
// What it does, in order:
//   1. Verifies the Cloudflare token and finds the account.
//   2. Finds the existing D1 binding id from the live settings.
//   3. Deploys middleware/src/index.js, re-applying BOTH existing
//      bindings (the DB D1 binding and the HOME_ALLOWED_EMAIL
//      plain-text variable the sign-in gate needs). A script
//      upload replaces the binding list, so dropping either would
//      silently break the gate or the ledger. Skipped if the live
//      script already carries this package's marker.
//   4. Read-back verification: marker + the DOOR/OpenClose
//      presentation on the live script; the binding list still
//      carries DB and HOME_ALLOWED_EMAIL; the expected secret
//      NAMES are present (names only, never values); /v1/health
//      answers ok.
//
// Non-interactive, idempotent, creates nothing on any provider
// control plane: it updates one existing Worker. Auth:
// CLOUDFLARE_API_TOKEN from the environment, or one line in
// ~/cloudflare-api-token.txt (a token with Workers Scripts Edit
// is enough). The token value is never printed.

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";

const API = "https://api.cloudflare.com/client/v4";
const WORKER_NAME = "andrew-middleware";
const DB_NAME = "middleware-ledger";
const MARKER = "contact-sensor-update-2026-11-15";
const TYPE_SNIPPET = "action.devices.types.DOOR";
const TRAIT_SNIPPET = "action.devices.traits.OpenClose";
const ALLOWED_EMAIL = "fourpshot@gmail.com";
const EXPECTED_SECRETS = [
  "MUSE_BEARER_TOKEN",
  "GOOGLE_HOME_SA_JSON",
  "HOME_LINK_CODE",
  "HOME_SIGNIN_CLIENT_ID",
  "HOME_SIGNIN_CLIENT_SECRET",
];

const scriptDir = dirname(fileURLToPath(import.meta.url));
const home = homedir();

let failed = false;
const ok = (m) => console.log(`✓ ${m}`);
const already = (m) => console.log(`✓ already — ${m}`);
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

console.log("=== Middleware contact-sensor update 2026-11-15 (owner-run) ===");

// --- 1. token + account -------------------------------------------------
const verification = await cf("/user/tokens/verify");
ok(`Token status: ${verification.status}`);
const accounts = await cf("/accounts");
if (!accounts.length) throw new Error("No Cloudflare accounts visible to this token.");
const account = accounts[0];
ok(`Account: ${account.name} (${account.id})`);

// --- 2. find the existing D1 binding id ----------------------------------
let dbId = null;
try {
  const settings = await cf(`/accounts/${account.id}/workers/scripts/${WORKER_NAME}/settings`);
  const binding = (settings.bindings || []).find((b) => b.name === "DB");
  if (binding) dbId = binding.id || binding.database_id || null;
} catch (e) { /* fall through to the D1 list lookup */ }
if (!dbId) {
  const dbs = await cf(`/accounts/${account.id}/d1/database?name=${DB_NAME}`);
  if (dbs[0]) dbId = dbs[0].uuid;
}
if (!dbId) throw new Error(`Could not find the '${DB_NAME}' D1 binding — run the setup/home update first.`);
ok(`D1 database binding found (${dbId}).`);

// --- 3. deploy the contact-sensor Worker source ---------------------------
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
  if (!code.includes(MARKER)) throw new Error(`Local source ${sourcePath} does not carry the ${MARKER} marker — is the fleet-kit checkout up to date (git pull)? Stopping.`);
  if (!code.includes(TYPE_SNIPPET) || !code.includes(TRAIT_SNIPPET)) throw new Error(`Local source does not present the device as ${TYPE_SNIPPET} + ${TRAIT_SNIPPET} — wrong checkout? Stopping.`);
  const metadata = {
    main_module: "index.js",
    compatibility_date: "2024-11-01",
    bindings: [
      { name: "DB", type: "d1", id: dbId },
      { name: "HOME_ALLOWED_EMAIL", type: "plain_text", text: ALLOWED_EMAIL },
    ],
  };
  const form = new FormData();
  form.append("metadata", new Blob([JSON.stringify(metadata)], { type: "application/json" }));
  form.append("index.js", new Blob([code], { type: "application/javascript+module" }), "index.js");
  await cf(`/accounts/${account.id}/workers/scripts/${WORKER_NAME}`, { method: "PUT", body: form });
  ok("Worker deployed (contact-sensor source; D1 binding + HOME_ALLOWED_EMAIL variable re-applied).");
}

// --- 4. read-back verification ----------------------------------------------
try {
  const live = await cfText(`/accounts/${account.id}/workers/scripts/${WORKER_NAME}`);
  if (live.includes(MARKER) && live.includes(TYPE_SNIPPET) && live.includes(TRAIT_SNIPPET)) ok("Read-back: live Worker carries the contact-sensor marker and the DOOR + OpenClose presentation.");
  else fail("Read-back: live Worker does NOT carry the contact-sensor change.");
} catch (e) {
  fail(`Read-back of the live script failed: ${e.message}`);
}

try {
  const settings = await cf(`/accounts/${account.id}/workers/scripts/${WORKER_NAME}/settings`);
  const names = (settings.bindings || []).map((b) => b.name);
  for (const needed of ["DB", "HOME_ALLOWED_EMAIL"]) {
    if (names.includes(needed)) ok(`Read-back: binding ${needed} present.`);
    else fail(`Read-back: binding ${needed} is NOT present — tell Muse before linking or pulsing.`);
  }
} catch (e) {
  fail(`Read-back of the binding list failed: ${e.message}`);
}

try {
  const secrets = await cf(`/accounts/${account.id}/workers/scripts/${WORKER_NAME}/secrets`);
  const names = secrets.map((s) => s.name);
  for (const needed of EXPECTED_SECRETS) {
    if (names.includes(needed)) ok(`Read-back: secret ${needed} present (name only).`);
    else fail(`Read-back: secret ${needed} is NOT present — an earlier leg regressed; tell Muse.`);
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
console.log("=== UPDATE APPLIED AND VERIFIED ===");
console.log("");
console.log("Remaining owner steps, in order:");
console.log("  1. In Google Home: unlink [test] Andrew Google Bridge, then link");
console.log("     it again (account chooser; pick fourpshot). A device TYPE");
console.log("     change only lands on a fresh SYNC, and the automatic");
console.log("     requestSync is still broken — the relink is what delivers");
console.log("     the new presentation.");
console.log("  2. MuseWakeUpTv comes back as a contact sensor (a door).");
console.log("     Build the routine with the starter 'MuseWakeUpTv opens'");
console.log("     and the action 'Bedroom TV on'.");
console.log("  3. Tell Muse — the next pulse opens the contact for 10");
console.log("     seconds, then closes it.");
console.log("You can now revoke the Cloudflare API token you used for this run.");
