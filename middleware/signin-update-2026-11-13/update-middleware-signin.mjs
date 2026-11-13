// update-middleware-signin.mjs — owner-run sign-in gate update for
// the andrew-middleware Worker (signin-update-2026-11-13).
//
// Why this exists: account linking for Andrew Google Bridge gets a
// Google sign-in gate (spec named-automations-spec-2026-11-13.md
// §11, approved by Andrew Nov 13, 2026). Instead of typing a link
// code, the owner signs in with Google on the /home/auth page and
// only fourpshot@gmail.com passes; any other account gets a
// dead-end page. The link code stays as a fallback until Andrew
// retires it. The same source also carries a diagnostic
// improvement: Home Graph failures now return Google's own error
// status/message (requestSync had been failing with a bare
// HTTP 400, which could not be diagnosed from outside).
// Middleware maintenance is OWNER-RUN by standing rule: Andrew
// runs this script once in Termux; it speaks the Cloudflare API
// directly (wrangler does not run in his Termux).
//
// What it does, in order:
//   1. Verifies the Cloudflare token and finds the account.
//   2. Deploys middleware/src/index.js, re-applying the existing
//      D1 binding and adding the HOME_ALLOWED_EMAIL plain-text
//      variable (fourpshot@gmail.com — the one account the gate
//      lets through; an address, not a secret). Skipped if the
//      live script already carries the signin-update marker.
//      NOTE for future update packages: a script upload replaces
//      the binding list, so later packages must keep carrying
//      BOTH bindings (DB + HOME_ALLOWED_EMAIL) or the gate
//      silently switches off and linking falls back to the code.
//   3. If MW_SIGNIN_CLIENT_ID and MW_SIGNIN_CLIENT_SECRET are
//      exported in the session, deposits them as the
//      HOME_SIGNIN_CLIENT_ID / HOME_SIGNIN_CLIENT_SECRET Worker
//      secrets (values entered on-device by the owner, never
//      printed, never carried in this repo). If they are not
//      exported and not already present, the update reports
//      INCOMPLETE with the console step that creates them.
//   4. Read-back verification: marker on the live script; secret
//      NAMES present (never values); /v1/health; and a functional
//      probe — GET /home/auth with Google-shaped parameters must
//      answer 302 to accounts.google.com once the gate is active.
//
// Non-interactive, idempotent, creates nothing on any provider
// control plane: it updates one existing Worker, its variables,
// and its secrets. Auth: CLOUDFLARE_API_TOKEN from the
// environment, or one line in ~/cloudflare-api-token.txt (a token
// with Workers Scripts Edit is enough). The token value and the
// client secret are never printed.

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";

const API = "https://api.cloudflare.com/client/v4";
const WORKER_NAME = "andrew-middleware";
const DB_NAME = "middleware-ledger";
const MARKER = "signin-update-2026-11-13";
const ALLOWED_EMAIL = "fourpshot@gmail.com";
const ID_SECRET = "HOME_SIGNIN_CLIENT_ID";
const SECRET_SECRET = "HOME_SIGNIN_CLIENT_SECRET";

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

console.log("=== Middleware sign-in gate update 2026-11-13 (owner-run) ===");

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

// --- 3. deploy the sign-in-aware Worker source ----------------------------
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
  ok("Worker deployed (sign-in gate source; D1 binding + HOME_ALLOWED_EMAIL variable applied).");
}

// --- 4. deposit the OAuth client credentials (if exported) -----------------
const clientId = (process.env.MW_SIGNIN_CLIENT_ID || "").trim();
const clientSecret = (process.env.MW_SIGNIN_CLIENT_SECRET || "").trim();
if (clientId && clientSecret) {
  await putSecret(account.id, ID_SECRET, clientId);
  await putSecret(account.id, SECRET_SECRET, clientSecret);
  ok("HOME_SIGNIN_CLIENT_ID + HOME_SIGNIN_CLIENT_SECRET deposited from the session environment (values entered on-device by the owner, never printed).");
} else if (clientId || clientSecret) {
  fail("Only one of MW_SIGNIN_CLIENT_ID / MW_SIGNIN_CLIENT_SECRET was exported — export BOTH (from the same OAuth client) and re-run.");
} else {
  skip("credential deposit not requested — export MW_SIGNIN_CLIENT_ID and MW_SIGNIN_CLIENT_SECRET in the session to include it.");
}

// --- 5. read-back verification ----------------------------------------------
try {
  const live = await cfText(`/accounts/${account.id}/workers/scripts/${WORKER_NAME}`);
  if (live.includes(MARKER)) ok("Read-back: live Worker carries the signin-update marker.");
  else fail("Read-back: live Worker does NOT carry the signin-update marker.");
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

let gateSecretsPresent = false;
try {
  const secrets = await cf(`/accounts/${account.id}/workers/scripts/${WORKER_NAME}/secrets`);
  const names = secrets.map((s) => s.name);
  for (const needed of ["MUSE_BEARER_TOKEN", "GOOGLE_HOME_SA_JSON", "HOME_LINK_CODE"]) {
    if (names.includes(needed)) ok(`Read-back: secret ${needed} present (name only).`);
    else fail(`Read-back: secret ${needed} is NOT present — an earlier leg regressed; tell Muse.`);
  }
  gateSecretsPresent = names.includes(ID_SECRET) && names.includes(SECRET_SECRET);
  if (gateSecretsPresent) {
    ok(`Read-back: secrets ${ID_SECRET} + ${SECRET_SECRET} present (names only) — the gate can activate.`);
  } else {
    fail(`Read-back: ${ID_SECRET} / ${SECRET_SECRET} not both present — the sign-in gate stays OFF and linking still uses the link code.`);
    console.log("    OWNER STEP (creates the credentials — one time):");
    console.log("    a. console.cloud.google.com → project andrew-mw-workspace →");
    console.log("       APIs & Services → OAuth consent screen: External, app name");
    console.log("       'Andrew Google Bridge', add fourpshot@gmail.com as a test user.");
    console.log("    b. APIs & Services → Credentials → Create credentials → OAuth");
    console.log("       client ID → Web application. Authorized redirect URI:");
    console.log(`       ${workerBase}/home/auth/callback`);
    console.log("    c. Copy the client ID and client secret from the console, then");
    console.log("       re-run this script with them exported:");
    console.log("       export MW_SIGNIN_CLIENT_ID=<the client ID>");
    console.log("       export MW_SIGNIN_CLIENT_SECRET=<the client secret>");
    console.log("       (Both values stay on this device and go straight to the");
    console.log("       Worker as secrets — never through chat, never to Muse.)");
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

// Functional probe: with the gate active, /home/auth must bounce to
// Google sign-in instead of serving the code form.
if (gateSecretsPresent && workerBase) {
  try {
    const probeUrl = `${workerBase}/home/auth?redirect_uri=${encodeURIComponent("https://oauth-redirect.googleusercontent.com/r/probe")}&state=probe&client_id=probe`;
    const res = await fetch(probeUrl, { redirect: "manual" });
    const loc = res.headers.get("Location") || "";
    if (res.status === 302 && loc.startsWith("https://accounts.google.com/")) {
      ok("Gate probe passed: /home/auth redirects to Google sign-in.");
    } else {
      fail(`Gate probe unexpected: HTTP ${res.status}, Location '${loc.slice(0, 60)}' — if the deploy just landed, wait a minute and re-run (verification only) to recheck.`);
    }
  } catch (e) {
    fail(`Gate probe failed: ${e.message}`);
  }
}

console.log("");
if (failed) {
  console.log("=== UPDATE INCOMPLETE — see ✗ lines above; nothing was rolled back, re-running is safe. ===");
  process.exit(1);
}
console.log("=== UPDATE APPLIED AND VERIFIED (script + gate credentials + health + gate probe) ===");
console.log("");
console.log("Remaining owner steps, in order:");
console.log("  1. In Google Home: unlink [test] Andrew Google Bridge, then link");
console.log("     it again. This time there is NO code page — Google shows the");
console.log("     account chooser; pick fourpshot and it links.");
console.log("  2. Check that the MuseWakeUpTv switch appears in the home");
console.log("     (the fresh link re-syncs the registry). Tell Muse either way —");
console.log("     if the switch is missing, the sync error now comes back with");
console.log("     Google's own explanation attached, and Muse will read it.");
console.log("  3. Optional but decisive: unlink once more and link choosing");
console.log("     andrewhorowitz3 — you should get a plain dead-end page:");
console.log("     'You can't use this. Bye.' Then link again as fourpshot.");
console.log("You can now revoke the Cloudflare API token you used for this run.");
