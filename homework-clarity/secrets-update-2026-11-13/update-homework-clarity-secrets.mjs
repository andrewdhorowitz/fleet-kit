// update-homework-clarity-secrets.mjs — owner-run secrets deposit
// for the homework-clarity Worker (homework-clarity/secrets-update-
// 2026-11-13).
//
// Why this exists: the Homework Clarity calendar connection (per-kid
// blocker calendars, built 2026-11-13) needs a Google OAuth client
// to run the consent flow, and the photo-scan extraction needs a
// Gemini API key. The live Worker currently has ZERO secrets, so
// Connect lands on the honest "oauth-not-configured" state and
// /extract returns the labeled sample fallback. This script
// deposits the secrets — all three in one run, or any subset:
// each export is independently optional, so a partial run now and
// a finishing run later is a supported path. Homework Clarity
// setup is OWNER-RUN
// by the same standing rule as middleware maintenance: Andrew runs
// this once in Termux; it speaks the Cloudflare API directly
// (wrangler does not run in his Termux).
//
// What it does, in order:
//   1. Reads the three session exports. Each is independently
//      OPTIONAL: whichever are exported (non-empty) get deposited
//      this run; the rest are skipped and named. Aborts cleanly,
//      before any API call, only if NONE of the three is set.
//      Partial runs are fine — re-running later with the remaining
//      exports set completes the set.
//   2. Verifies the Cloudflare token and confirms it can see the
//      fleet account (pinned id below).
//   3. Deposits each exported value as a Worker secret on the
//      homework-clarity script:
//        HC_GOOGLE_CLIENT_ID     -> GOOGLE_CLIENT_ID
//        HC_GOOGLE_CLIENT_SECRET -> GOOGLE_CLIENT_SECRET
//        HC_GEMINI_API_KEY       -> GEMINI_API_KEY
//      (values entered on-device by the owner, never printed,
//      never carried in this repo).
//   4. Read-back verification: lists the Worker's secret NAMES and
//      asserts the ones set in this run are present (names only,
//      never values); also reports which of the three are still
//      missing overall.
//   5. Prints the two remaining manual console steps (OAuth
//      redirect URI + Firestore rules republish).
//
// Non-interactive, idempotent (re-running just rewrites the same
// secrets), creates nothing on any provider control plane: it only
// sets secrets on one existing Worker. Auth: CLOUDFLARE_API_TOKEN
// from the environment, or one line in ~/cloudflare-api-token.txt
// (a token with Workers Scripts Edit on the account is enough).
// No value — token, client secret, API key — is ever printed.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const API = "https://api.cloudflare.com/client/v4";
const ACCOUNT_ID = "2e2d28cfd77d3c1215cbe512c7fd2733";
const WORKER_NAME = "homework-clarity";

// Session export name -> Worker secret name.
const SECRETS = [
  ["HC_GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_ID"],
  ["HC_GOOGLE_CLIENT_SECRET", "GOOGLE_CLIENT_SECRET"],
  ["HC_GEMINI_API_KEY", "GEMINI_API_KEY"],
];

const home = homedir();

let failed = false;
const ok = (m) => console.log(`✓ ${m}`);
const fail = (m) => { failed = true; console.log(`✗ ${m}`); };

// --- 0. session exports first (before ANY api call) ---------------------
// Each export is independently optional: deposit whichever are set,
// skip (and name) the rest, abort only if none is set.
const values = {};
const toSet = [];
const skipped = [];
for (const [envName, secretName] of SECRETS) {
  const v = (process.env[envName] || "").trim();
  if (v) { values[secretName] = v; toSet.push([envName, secretName]); }
  else skipped.push(envName);
}
if (!toSet.length) {
  console.error("No session exports set — nothing was sent anywhere. Export at least one of the three, then re-run:");
  for (const [envName] of SECRETS) console.error(`  export ${envName}=<value>`);
  console.error("Values come from your own consoles (see this package's README, step YOU-1) and stay on this device.");
  process.exit(1);
}
ok(`Exports present this run: ${toSet.map(([envName]) => envName).join(", ")} (values not printed).`);
if (skipped.length) {
  console.log(`Skipping (not exported this run): ${skipped.join(", ")} — re-run later with those exports set to complete the set.`);
}

// --- token ---------------------------------------------------------------
let token = (process.env.CLOUDFLARE_API_TOKEN || "").trim();
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

console.log("=== Homework Clarity secrets update 2026-11-13 (owner-run) ===");

// --- 1. token + account ---------------------------------------------------
const verification = await cf("/user/tokens/verify");
ok(`Token status: ${verification.status}`);
const accounts = await cf("/accounts");
const account = accounts.find((a) => a.id === ACCOUNT_ID);
if (!account) {
  console.error(`This token cannot see the fleet account ${ACCOUNT_ID} — it needs Workers Scripts Edit on that account. Stopping; nothing was changed.`);
  process.exit(1);
}
ok(`Account confirmed: ${account.name} (${account.id})`);

// --- 2. deposit the exported secrets --------------------------------------
for (const [, secretName] of toSet) {
  await cf(`/accounts/${ACCOUNT_ID}/workers/scripts/${WORKER_NAME}/secrets`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: secretName, text: values[secretName], type: "secret_text" }),
  });
  ok(`Secret ${secretName} deposited on ${WORKER_NAME} (value not printed).`);
}

// --- 3. read-back verification (names only) ---------------------------------
let stillMissing = SECRETS.map(([, secretName]) => secretName);
try {
  const secrets = await cf(`/accounts/${ACCOUNT_ID}/workers/scripts/${WORKER_NAME}/secrets`);
  const names = secrets.map((s) => s.name);
  for (const [, secretName] of toSet) {
    if (names.includes(secretName)) ok(`Read-back: secret ${secretName} present (name only).`);
    else fail(`Read-back: secret ${secretName} is NOT present — the deposit did not land; tell Muse.`);
  }
  stillMissing = SECRETS.map(([, secretName]) => secretName).filter((n) => !names.includes(n));
  if (stillMissing.length) {
    console.log(`Still missing on ${WORKER_NAME} (not set in this or any earlier run): ${stillMissing.join(", ")} — a later run with the matching exports set completes the set.`);
  }
} catch (e) {
  fail(`Read-back of the secret list failed: ${e.message}`);
}

console.log("");
if (failed) {
  console.log("=== SECRETS UPDATE INCOMPLETE — see ✗ lines above; nothing was rolled back, re-running is safe. ===");
  process.exit(1);
}
if (!stillMissing.length) {
  console.log("=== SECRETS SET AND VERIFIED (all three names present on homework-clarity) ===");
} else {
  console.log(`=== PARTIAL RUN COMPLETE — ${toSet.map(([, s]) => s).join(", ")} deposited and verified; still missing: ${stillMissing.join(", ")} ===`);
}
console.log("");
console.log("Two manual steps remain before the in-app Connect flow can finish.");
console.log("They are console work only Muse cannot do for you:");
console.log("");
console.log("  1. Google Cloud Console — authorize the Worker's callback URL");
console.log("     on the SAME OAuth client you just deposited:");
console.log("       console.cloud.google.com → project gen-lang-client-0590645241");
console.log("       → APIs & Services → Credentials → your OAuth web client");
console.log("       → Authorized redirect URIs → Add URI, exactly:");
console.log("       https://homework.andrewdhorowitz.com/calendar/auth/callback");
console.log("       → Save. (Without this, Google refuses the consent at the");
console.log("       last step with a redirect_uri_mismatch error.)");
console.log("");
console.log("  2. Firebase console — republish the Firestore rules (the widened");
console.log("     version that lets a parent save each kid's blocker-calendar");
console.log("     pick; the pickers cannot save until this lands):");
console.log("       console.firebase.google.com → project gen-lang-client-0590645241");
console.log("       → Firestore Database → Rules → replace the editor contents");
console.log("       with the rules file from the homework-clarity project");
console.log("       (firestore/firestore.rules in that repo — ask Muse to show");
console.log("       you the current text) → Publish.");
console.log("");
console.log("Then tell Muse: the consent sitting in the app (sign in as");
console.log("fourpshot → Parent view → Connect calendar → approve → pick");
console.log("Alexis → her calendar, Bailey → hers) is the last step, and Muse");
console.log("verifies the grant landed server-side afterwards.");
console.log("You can now revoke the Cloudflare API token you used for this run.");
