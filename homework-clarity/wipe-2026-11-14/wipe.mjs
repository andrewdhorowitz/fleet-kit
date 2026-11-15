#!/usr/bin/env node
// wipe.mjs — owner-run FULL WIPE for Homework Clarity
// (homework-clarity/wipe-2026-11-14).
//
// Deletes, in project gen-lang-client-0590645241 ONLY:
//   - every document in every top-level Firestore collection
//     (families, registry, and any others found at runtime),
//     including all subcollections, and
//   - every Firebase Auth user in the project.
//
// Safety shape (see README.md):
//   1. INVENTORY — lists Auth users and Firestore collections with
//      document counts and prints all of it before anything else.
//   2. BACKUP — exports the Auth user list and every Firestore
//      document to a timestamped JSON file in this folder. If the
//      backup cannot be written and re-read, the script aborts
//      with nothing deleted. This is a one-way door; the backup
//      is the only recovery.
//   3. CONFIRM — Andrew must type WIPE at the prompt. Anything
//      else aborts with nothing deleted.
//   4. DELETE — Firestore documents deepest-first (subcollection
//      documents before their parents), then Auth users in
//      batches of 1000.
//   5. VERIFY — re-lists both stores and prints a plain summary.
//      Leftovers are named, never hidden.
//
// The project is PINNED in the constant below and in every URL.
// There is deliberately no flag, argument, or environment variable
// that can retarget this script; if GCLOUD_PROJECT /
// FIREBASE_PROJECT point somewhere else, it refuses to run.
//
// Auth: borrows the Firebase CLI's own saved OAuth credential
// (~/.config/configstore/firebase-tools.json — the same sign-in
// the rules-publish package uses) and calls the Firestore REST
// API and the Identity Toolkit API with it. wipe.sh checks the
// CLI sign-in first and runs `firebase login --no-localhost`
// only if none is live.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

const PROJECT = "gen-lang-client-0590645241";
const FS_BASE = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)`;
const DOCS_PARENT = `projects/${PROJECT}/databases/(default)/documents`;
const HERE = path.dirname(fileURLToPath(import.meta.url));

function die(msg) {
  console.error(`\n✗ ${msg}`);
  process.exit(1);
}

// --- project pin guard -------------------------------------------------------
for (const v of ["GCLOUD_PROJECT", "FIREBASE_PROJECT"]) {
  if (process.env[v] && process.env[v] !== PROJECT) {
    die(`${v} is set to "${process.env[v]}" — this script only ever touches ${PROJECT}. Unset it and re-run.`);
  }
}
if (process.argv.length > 2) {
  die("This script takes no arguments — the target project is pinned in the script. Re-run with no arguments.");
}

// --- access token from the Firebase CLI's saved credential -------------------
async function accessToken() {
  const cfgPath = path.join(os.homedir(), ".config/configstore/firebase-tools.json");
  let cfg;
  try {
    cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
  } catch {
    die("No Firebase CLI credential found — wipe.sh should have run the sign-in first.");
  }
  const tok = cfg.tokens || {};
  let access = tok.access_token;
  const expired = !tok.expires_at || Date.now() > tok.expires_at - 60000;
  if ((!access || expired) && tok.refresh_token) {
    const body = new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: tok.refresh_token,
      client_id: "563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com",
      client_secret: "j9iVZfS8kkCEFUPaAeJV0sAi",
    });
    const r = await fetch("https://oauth2.googleapis.com/token", { method: "POST", body });
    const j = await r.json().catch(() => ({}));
    access = j.access_token;
  }
  if (!access) die("Could not mint an access token from the Firebase CLI sign-in — re-run wipe.sh and complete the sign-in.");
  return access;
}

let ACCESS = null;
async function api(url, { method = "GET", body } = {}) {
  const r = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${ACCESS}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await r.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* leave null */ }
  return { status: r.status, ok: r.ok, json, text };
}

function apiError(what, res) {
  const detail = res.json?.error?.message || res.text?.slice(0, 300) || "(no detail)";
  return `${what} failed (HTTP ${res.status}): ${detail}`;
}

// --- Firestore helpers ---------------------------------------------------------
// Document resource names contain path segments that may need URL
// encoding; encode only the part after "/documents/".
function encName(name) {
  const marker = "/documents/";
  const i = name.indexOf(marker);
  if (i < 0) return name;
  const head = name.slice(0, i + marker.length);
  const tail = name.slice(i + marker.length).split("/").map(encodeURIComponent).join("/");
  return head + tail;
}
const docUrl = (name) => `https://firestore.googleapis.com/v1/${encName(name)}`;

async function listCollectionIds(parentName) {
  const res = await api(`${docUrl(parentName)}:listCollectionIds`, { method: "POST", body: {} });
  if (!res.ok) throw new Error(apiError(`listCollectionIds(${parentName})`, res));
  return res.json?.collectionIds || [];
}

async function listDocsPage(parentName, collectionId, pageToken) {
  // List documents URL: {database}/documents/{collection} at the root,
  // {documentName}/{collection} for a subcollection.
  const base = parentName === DOCS_PARENT
    ? `${FS_BASE}/documents`
    : `https://firestore.googleapis.com/v1/${encName(parentName)}`;
  let url = `${base}/${encodeURIComponent(collectionId)}?pageSize=300`;
  if (pageToken) url += `&pageToken=${encodeURIComponent(pageToken)}`;
  const res = await api(url);
  if (!res.ok) throw new Error(apiError(`list documents in ${collectionId}`, res));
  return res.json || {};
}

// Recursively collect every document under a collection, depth-first.
async function walkCollection(parentName, collectionId, out) {
  let pageToken = undefined;
  do {
    const page = await listDocsPage(parentName, collectionId, pageToken);
    for (const doc of page.documents || []) {
      out.push(doc);
      const subs = await listCollectionIds(doc.name);
      for (const sub of subs) await walkCollection(doc.name, sub, out);
    }
    pageToken = page.nextPageToken;
  } while (pageToken);
}

async function collectFirestore() {
  const rootIds = await listCollectionIds(DOCS_PARENT);
  const byCollection = {};
  const all = [];
  for (const id of rootIds) {
    const docs = [];
    await walkCollection(DOCS_PARENT, id, docs);
    byCollection[id] = docs;
    all.push(...docs);
  }
  return { rootIds, byCollection, all };
}

// --- Firebase Auth helpers -----------------------------------------------------
async function listUsersDownload() {
  const users = [];
  let nextPageToken = undefined;
  do {
    const body = { targetProjectId: PROJECT, maxResults: 1000 };
    if (nextPageToken) body.nextPageToken = nextPageToken;
    const res = await api("https://www.googleapis.com/identitytoolkit/v3/relyingparty/downloadAccount", { method: "POST", body });
    if (!res.ok) throw new Error(apiError("downloadAccount", res));
    users.push(...(res.json?.users || []));
    nextPageToken = res.json?.nextPageToken;
  } while (nextPageToken);
  return users.map((u) => ({
    localId: u.localId,
    email: u.email || null,
    createdAt: u.createdAt ? new Date(Number(u.createdAt)).toISOString() : null,
    raw: u,
  }));
}

async function listUsersQuery() {
  const users = [];
  let offset = 0;
  for (;;) {
    const res = await api(`https://identitytoolkit.googleapis.com/v1/projects/${PROJECT}/accounts:query`, {
      method: "POST",
      body: { returnUserInfo: true, limit: 1000, offset },
    });
    if (!res.ok) throw new Error(apiError("accounts:query", res));
    const page = res.json?.userInfo || [];
    for (const u of page) {
      users.push({
        localId: u.localId,
        email: u.email || null,
        createdAt: u.createdAt || null,
        raw: u,
      });
    }
    if (page.length < 1000) break;
    offset += page.length;
  }
  return users;
}

async function listAllUsers() {
  try {
    return await listUsersDownload();
  } catch (e1) {
    try {
      return await listUsersQuery();
    } catch (e2) {
      die(`Could not list Auth users. downloadAccount: ${e1.message} | accounts:query: ${e2.message}`);
    }
  }
}

async function batchDeleteUsers(localIds) {
  const failures = [];
  let deleted = 0;
  for (let i = 0; i < localIds.length; i += 1000) {
    const chunk = localIds.slice(i, i + 1000);
    const res = await api(`https://identitytoolkit.googleapis.com/v1/projects/${PROJECT}/accounts:batchDelete`, {
      method: "POST",
      body: { localIds: chunk },
    });
    if (!res.ok) {
      for (const id of chunk) failures.push({ localId: id, message: apiError("batchDelete", res) });
      continue;
    }
    const errored = new Set((res.json?.errors || []).map((e) => chunk[e.index]));
    for (const e of res.json?.errors || []) {
      failures.push({ localId: chunk[e.index], message: e.message || "unknown error" });
    }
    deleted += chunk.length - errored.size;
  }
  return { deleted, failures };
}

// --- main ----------------------------------------------------------------------
async function main() {
  console.log("=== Homework Clarity FULL WIPE (owner-run) ===");
  console.log(`Target project (pinned): ${PROJECT}`);
  console.log("This deletes ALL Firestore documents and ALL Auth users in that project.\n");

  ACCESS = await accessToken();

  // Who is signed in (informational; the CLI token carries openid/email).
  try {
    const me = await api("https://openidconnect.googleapis.com/v1/userinfo");
    if (me.ok && me.json?.email) console.log(`Firebase CLI sign-in: ${me.json.email}`);
  } catch { /* informational only */ }

  // Sanity: the database that answers must be the pinned project.
  const dbRes = await api(FS_BASE);
  if (!dbRes.ok) die(apiError("Firestore database check", dbRes) + "\nIs the CLI signed in as the project owner (andrewhorowitz3)? Nothing was deleted.");
  const dbName = dbRes.json?.name || "";
  if (!dbName.startsWith(`projects/${PROJECT}/`)) {
    die(`Database check answered for "${dbName}", not ${PROJECT} — aborting. Nothing was deleted.`);
  }

  // ---- 1. INVENTORY -----------------------------------------------------------
  console.log("\n--- Inventory ------------------------------------------------");
  const users = await listAllUsers();
  console.log(`Auth users: ${users.length}`);
  for (const u of users) {
    console.log(`  - ${u.email || "(no email)"}  uid ${u.localId}${u.createdAt ? `  created ${u.createdAt}` : ""}`);
  }
  const fsInv = await collectFirestore();
  console.log(`Firestore top-level collections: ${fsInv.rootIds.length ? fsInv.rootIds.join(", ") : "(none)"}`);
  for (const id of fsInv.rootIds) {
    console.log(`  - ${id}: ${fsInv.byCollection[id].length} document(s) incl. subcollections`);
  }
  console.log(`Firestore documents total: ${fsInv.all.length}`);

  if (users.length === 0 && fsInv.all.length === 0) {
    console.log("\nNothing to wipe — the project is already empty.");
    return;
  }

  // ---- 2. BACKUP ---------------------------------------------------------------
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const backupPath = path.join(HERE, `backup-${stamp}.json`);
  const payload = {
    project: PROJECT,
    exportedAt: new Date().toISOString(),
    authUsers: users.map((u) => u.raw),
    firestoreDocuments: fsInv.all.map((d) => ({
      name: d.name,
      createTime: d.createTime || null,
      updateTime: d.updateTime || null,
      fields: d.fields || {},
    })),
  };
  try {
    fs.writeFileSync(backupPath, JSON.stringify(payload, null, 2));
    const check = JSON.parse(fs.readFileSync(backupPath, "utf8"));
    if (!check || check.project !== PROJECT || !Array.isArray(check.firestoreDocuments)) {
      throw new Error("backup re-read check failed");
    }
  } catch (e) {
    die(`Backup failed (${e.message}) — aborting. Nothing was deleted.`);
  }
  console.log(`\n✓ Backup written and re-read OK: ${backupPath}`);
  console.log("  It is the ONLY recovery for what this wipe deletes. It sits inside");
  console.log("  your fleet-kit working copy — a .gitignore in this folder keeps it");
  console.log("  out of git; do not commit or share it.");

  // ---- 3. CONFIRM ---------------------------------------------------------------
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const answer = await new Promise((resolve) => {
    rl.question(
      `\nType WIPE to permanently delete ${users.length} Auth user(s) and ${fsInv.all.length} Firestore document(s) in ${PROJECT}: `,
      (a) => { rl.close(); resolve(a); }
    );
  });
  if (String(answer).trim() !== "WIPE") {
    console.log("Not confirmed — aborting. Nothing was deleted.");
    return;
  }

  // ---- 4. DELETE ------------------------------------------------------------------
  console.log("\n--- Deleting Firestore documents (deepest first) ----------------");
  const depth = (name) => name.split("/").length;
  const ordered = [...fsInv.all].sort((a, b) => depth(b.name) - depth(a.name));
  let fsDeleted = 0;
  const fsFailures = [];
  for (const doc of ordered) {
    const res = await api(docUrl(doc.name), { method: "DELETE" });
    if (res.ok || res.status === 404) fsDeleted++;
    else fsFailures.push({ name: doc.name, message: apiError("delete document", res) });
  }
  console.log(`Firestore: ${fsDeleted} deleted, ${fsFailures.length} failed.`);
  for (const f of fsFailures) console.log(`  ✗ ${f.name} — ${f.message}`);

  console.log("\n--- Deleting Auth users ------------------------------------------");
  let authDeleted = 0;
  let authFailures = [];
  if (users.length) {
    const r = await batchDeleteUsers(users.map((u) => u.localId));
    authDeleted = r.deleted;
    authFailures = r.failures;
  }
  console.log(`Auth: ${authDeleted} deleted, ${authFailures.length} failed.`);
  for (const f of authFailures) console.log(`  ✗ uid ${f.localId} — ${f.message}`);

  // ---- 5. VERIFY ---------------------------------------------------------------------
  console.log("\n--- Verify ---------------------------------------------------------");
  const usersAfter = await listAllUsers();
  const fsAfter = await collectFirestore();
  console.log(`Auth users remaining: ${usersAfter.length}`);
  for (const u of usersAfter) console.log(`  - ${u.email || "(no email)"}  uid ${u.localId}`);
  console.log(`Firestore documents remaining: ${fsAfter.all.length}`);
  for (const d of fsAfter.all.slice(0, 20)) console.log(`  - ${d.name}`);
  if (fsAfter.all.length > 20) console.log(`  … and ${fsAfter.all.length - 20} more`);

  if (usersAfter.length === 0 && fsAfter.all.length === 0) {
    console.log(`\n=== WIPE COMPLETE — ${PROJECT} is empty ===`);
    console.log(`Deleted ${fsDeleted} Firestore document(s) and ${authDeleted} Auth user(s).`);
    console.log(`Backup (only recovery): ${backupPath}`);
    console.log("Next: clear the Homework Clarity app's cache and data on your phone,");
    console.log("sign in fresh, and create the family. Tell Muse the wipe ran.");
  } else {
    console.log("\n=== WIPE FINISHED WITH LEFTOVERS — see the counts above ===");
    console.log("Nothing above is hidden: re-running this script takes a fresh");
    console.log("inventory + backup and can delete what remains. Tell Muse.");
    process.exitCode = 2;
  }
}

main().catch((e) => die(e.message || String(e)));
