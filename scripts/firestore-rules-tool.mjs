#!/usr/bin/env node
/**
 * firestore-rules-tool.mjs — drift-guarded Firestore rules publish + live
 * probes for the fleet's Firebase project (family-routines-app).
 *
 * Built for error-reporting Phase 1 Step 1 (the error_reports rules block),
 * but deliberately generic: it publishes whatever firestore.rules the
 * target repo checkout carries, under the fleet's firebase-leg semantics
 * (the design first proven in the routines repo's setup-settings.sh
 * `firebase` section, Oct 29 2026):
 *
 *   compile-validate -> drift check (live must equal the expected prior
 *   source, canonical compare) -> deploy ONLY if changed -> verify the
 *   release re-points and the live source matches.
 *
 * All Rules-API request shapes are the ones proven live by fleet-kit's
 * scripts/firebase-converge.sh (step 3), including the UpdateReleaseRequest
 * wrapper on the release PATCH (a bare {rulesetName} body is rejected).
 *
 * Modes (argv[2]):
 *   read-live   Print the live release + ruleset names and whether the
 *               live source canonically equals NEW_RULES (and PRIOR_RULES
 *               when given). No writes.
 *   publish     Compile-validate NEW_RULES; refuse unless the live source
 *               canonically equals PRIOR_RULES (the drift guard); create
 *               the ruleset, PATCH the cloud.firestore release to it, and
 *               verify both the release pointer and the live source.
 *   rollback    PATCH the release back to ROLLBACK_RULESET; verify.
 *   probe       Run the live probe suite against error_reports + the
 *               unauthenticated regression set. Creates two throwaway
 *               Auth users, temporarily seats one in system_admins, and
 *               removes every artifact it created (docs, seat, users)
 *               before exiting. Verifies rules as REAL clients see them:
 *               no token, a regular user's ID token, an admin's ID token.
 *
 * Auth: GOOGLE_APPLICATION_CREDENTIALS (ADC) — in CI the
 * FIREBASE_SERVICE_ACCOUNT_JSON repo secret, materialized by the
 * .github/workflows/firestore-rules.yml workflow exactly as the
 * private-section firebase-admin workflow does. The credential, access
 * tokens, custom tokens, ID tokens, and the app API key are NEVER
 * printed; the only key material ever logged is the API key's last 4
 * (fleet convention for the public web key, which ships in the page).
 *
 * Results are appended to RESULTS_FILE (default
 * firestore-rules-results.txt in the cwd) and echoed to stdout; the
 * workflow commits the results file back to fleet-kit so the run can be
 * read and fixed from GitHub (the converger contract).
 */
import { initializeApp, applicationDefault } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { getAuth } from 'firebase-admin/auth';
import fs from 'node:fs';

const PROJECT = 'family-routines-app';
const RESULTS = process.env.RESULTS_FILE || 'firestore-rules-results.txt';
const MODE = process.argv[2];
const RULES_API = 'https://firebaserules.googleapis.com/v1';
const FS_API = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents`;
const RELEASE_URL = `${RULES_API}/projects/${PROJECT}/releases/cloud.firestore`;

fs.writeFileSync(RESULTS, '');
function log(line) {
  fs.appendFileSync(RESULTS, line + '\n');
  console.log(line);
}
function fail(line) {
  log('FAIL ' + line);
  process.exitCode = 1;
}

const canonical = (text) =>
  text.split('\n').map((l) => l.trim()).filter((l) => l).join('\n');

let ACCESS;

async function api(method, url, body) {
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${ACCESS}`,
      'Content-Type': 'application/json',
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* leave null */ }
  return { status: res.status, json, text };
}

async function readLive() {
  const rel = await api('GET', RELEASE_URL);
  if (rel.status !== 200 || !rel.json?.rulesetName) {
    throw new Error(`release read failed: HTTP ${rel.status} ${rel.text.slice(0, 300)}`);
  }
  const name = rel.json.rulesetName;
  const rs = await api('GET', `${RULES_API}/${name}`);
  if (rs.status !== 200) {
    throw new Error(`ruleset read failed: HTTP ${rs.status} ${rs.text.slice(0, 300)}`);
  }
  const files = rs.json?.source?.files || [];
  const source = files.map((f) => f.content || '').join('\n');
  return { rulesetName: name, source };
}

function firstDiff(a, b) {
  const la = a.split('\n'), lb = b.split('\n');
  const n = Math.max(la.length, lb.length);
  for (let i = 0; i < n; i++) {
    if (la[i] !== lb[i]) return { line: i + 1, a: la[i] ?? '<missing>', b: lb[i] ?? '<missing>' };
  }
  return null;
}

try {
  log(`firestore-rules tool — mode=${MODE} project=${PROJECT}`);
  log(`when: ${new Date().toISOString()}`);
  const credential = applicationDefault();
  initializeApp({ credential, projectId: PROJECT });
  ACCESS = (await credential.getAccessToken()).access_token;

  if (MODE === 'read-live') {
    const live = await readLive();
    log(`live release ruleset: ${live.rulesetName}`);
    log(`live rules for rollback: PATCH release rulesetName -> ${live.rulesetName}`);
    for (const [label, path] of [['NEW_RULES', process.env.NEW_RULES], ['PRIOR_RULES', process.env.PRIOR_RULES]]) {
      if (path && fs.existsSync(path) && fs.statSync(path).size > 0) {
        const src = fs.readFileSync(path, 'utf8');
        const eq = canonical(live.source) === canonical(src);
        log(`${label}: canonical-equal to live = ${eq}`);
        if (!eq) {
          const d = firstDiff(canonical(live.source), canonical(src));
          log(`${label}: first diff at canonical line ${d.line}: live=${JSON.stringify(d.a)} file=${JSON.stringify(d.b)}`);
        }
      } else {
        log(`${label}: not provided`);
      }
    }
    log('read-live: OK');
  } else if (MODE === 'publish') {
    const newSource = fs.readFileSync(process.env.NEW_RULES, 'utf8');
    const priorSource = fs.readFileSync(process.env.PRIOR_RULES, 'utf8');
    // 1. Compile-validate (projects.test — the firebase leg's read-only check).
    const t = await api('POST', `${RULES_API}/projects/${PROJECT}:test`, {
      source: { files: [{ name: 'firestore.rules', content: newSource }] },
    });
    const issues = (t.json?.issues || []).filter((i) => i.severity === 'ERROR');
    if (issues.length > 0) {
      fail(`publish: compile validation failed (HTTP ${t.status}, ${issues.length} error issue(s)): ${JSON.stringify(issues).slice(0, 500)}`);
      throw new Error('abort');
    }
    if (t.status !== 200) {
      // Advisory only (fix 2026-10-30): projects:test returns HTTP 403 for
      // this service account with zero ERROR issues — the account can read
      // releases/rulesets, create rulesets, and PATCH releases (proven by
      // firebase-converge.sh step 3, which never calls :test), but lacks
      // the test permission. Ruleset creation below remains the server-side
      // compile gate: invalid rules fail creation and are never released.
      log(`publish: projects.test advisory — HTTP ${t.status}, 0 ERROR issues; body: ${t.text.slice(0, 300)}; proceeding (ruleset create is the compile gate)`);
    } else {
      log('publish: compile validation clean (projects.test, no ERROR issues)');
    }
    // 2. Drift guard: live must equal the expected prior source.
    const live = await readLive();
    log(`publish: live ruleset before = ${live.rulesetName}`);
    if (canonical(live.source) === canonical(newSource)) {
      log('publish: live already equals the new source — nothing deployed (deploy-if-changed)');
    } else {
      if (canonical(live.source) !== canonical(priorSource)) {
        const d = firstDiff(canonical(live.source), canonical(priorSource));
        fail(`publish: DRIFT — live rules differ from the expected prior source; refusing to publish. First diff at canonical line ${d.line}: live=${JSON.stringify(d.a)} prior=${JSON.stringify(d.b)}`);
        throw new Error('abort');
      }
      log('publish: drift guard passed (live == expected prior source)');
      // 3. Create the ruleset.
      const cr = await api('POST', `${RULES_API}/projects/${PROJECT}/rulesets`, {
        source: { files: [{ name: 'firestore.rules', content: newSource }] },
      });
      if (cr.status !== 200 || !cr.json?.name) {
        fail(`publish: ruleset create failed: HTTP ${cr.status} ${cr.text.slice(0, 300)}`);
        throw new Error('abort');
      }
      const newName = cr.json.name;
      log(`publish: ruleset created = ${newName}`);
      // 4. Re-point the release (UpdateReleaseRequest wrapper — proven shape).
      const patch = await api('PATCH', RELEASE_URL, {
        release: { name: `projects/${PROJECT}/releases/cloud.firestore`, rulesetName: newName },
        updateMask: 'rulesetName',
      });
      if (patch.status !== 200) {
        fail(`publish: release PATCH failed: HTTP ${patch.status} ${patch.text.slice(0, 300)} — new ruleset ${newName} exists but is NOT live; prior ruleset ${live.rulesetName} is still serving.`);
        throw new Error('abort');
      }
      // 5. Verify pointer + live source.
      const after = await readLive();
      if (after.rulesetName !== newName) {
        fail(`publish: release verify failed — release points at ${after.rulesetName}, expected ${newName}`);
        throw new Error('abort');
      }
      if (canonical(after.source) !== canonical(newSource)) {
        fail('publish: live source verify failed — canonical live != new source after publish');
        throw new Error('abort');
      }
      log(`publish: OK — release now serves ${newName}; live source canonically equals the new repo source`);
      log(`rollback handle: dispatch mode=rollback with rollback_ruleset=${live.rulesetName}`);
    }
  } else if (MODE === 'rollback') {
    const target = process.env.ROLLBACK_RULESET;
    if (!target) { fail('rollback: ROLLBACK_RULESET not provided'); throw new Error('abort'); }
    const before = await readLive();
    log(`rollback: live ruleset before = ${before.rulesetName}; target = ${target}`);
    const patch = await api('PATCH', RELEASE_URL, {
      release: { name: `projects/${PROJECT}/releases/cloud.firestore`, rulesetName: target },
      updateMask: 'rulesetName',
    });
    if (patch.status !== 200) {
      fail(`rollback: release PATCH failed: HTTP ${patch.status} ${patch.text.slice(0, 300)}`);
      throw new Error('abort');
    }
    const after = await readLive();
    if (after.rulesetName !== target) {
      fail(`rollback: verify failed — release points at ${after.rulesetName}, expected ${target}`);
      throw new Error('abort');
    }
    log(`rollback: OK — release now serves ${target}`);
  } else if (MODE === 'probe') {
    await probe();
  } else {
    fail(`unknown mode: ${MODE}`);
  }
} catch (e) {
  if (e.message !== 'abort') fail(`tool error: ${e.message}`);
}

async function probe() {
  const S = (v) => ({ stringValue: v });
  const I = (v) => ({ integerValue: String(v) });
  const B = (v) => ({ booleanValue: v });
  const NL = () => ({ nullValue: null });
  const baseDoc = () => ({
    fields: {
      code: S('probe/step1'), tier: I(1), area: S('tasks'),
      operation: S('step1-probe'), recovered: B(false),
      release: S('step1-probe'), page: S('/'), site: S('routines-and-streaks'),
      ts: I(1793500000000),
    },
  });
  async function call(method, url, token, body) {
    const headers = { 'Content-Type': 'application/json' };
    if (token) headers.Authorization = `Bearer ${token}`;
    const res = await fetch(url, {
      method, headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch { /* null */ }
    return { status: res.status, json };
  }
  let failures = 0;
  function check(name, got, want) {
    const ok = got === want;
    if (!ok) failures++;
    log(`${ok ? 'PASS' : 'FAIL'} probe ${name}: HTTP ${got} (want ${want})`);
  }

  const db = getFirestore();
  const auth = getAuth();
  const REG = 'probe-regular-step1';
  const ADM = 'probe-admin-step1';
  const created = [];
  try {
    // Throwaway users + temporary admin seat (all removed in finally).
    // Users carry a per-run password (generated here, never logged) so ID
    // tokens come from email/password sign-in: custom-token minting needs
    // the IAM Service Account Credentials API (signBlob), which is disabled
    // in this project (probe failure, 2026-10-30).
    const PROBE_PW = 'Probe!' + Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2) + '9';
    for (const uid of [REG, ADM]) {
      const email = `${uid}@example.com`;
      try {
        await auth.getUser(uid);
        await auth.updateUser(uid, { email, password: PROBE_PW });
      } catch { await auth.createUser({ uid, email, password: PROBE_PW }); }
    }
    await db.doc(`system_admins/${ADM}`).set({ enabled: true });
    log('probe: throwaway users created; temporary admin seat granted (removed below)');

    // ID tokens via email/password sign-in with the app's public web key,
    // presenting a referer the key's allowlist accepts (never logged).
    const pageHtml = await (await fetch('https://routines.andrewdhorowitz.com/')).text();
    const keyMatch = pageHtml.match(/apiKey:\s*"([^"]+)"/);
    if (!keyMatch) { fail('probe: could not find apiKey in the live page'); return; }
    const apiKey = keyMatch[1];
    log(`probe: live page apiKey found (…${apiKey.slice(-4)})`);
    async function idToken(uid) {
      const email = `${uid}@example.com`;
      for (const ref of ['https://routines.andrewdhorowitz.com/', 'https://andrewdhorowitz.github.io/', null]) {
        const headers = { 'Content-Type': 'application/json' };
        if (ref) headers.Referer = ref;
        const res = await fetch(
          `https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${apiKey}`,
          { method: 'POST', headers, body: JSON.stringify({ email, password: PROBE_PW, returnSecureToken: true }) },
        );
        const j = await res.json().catch(() => null);
        if (res.status === 200 && j?.idToken) {
          log(`probe: token exchange for ${uid} OK (referer class: ${ref ? new URL(ref).host : 'none'})`);
          return j.idToken;
        }
      }
      throw new Error(`token exchange failed for ${uid}`);
    }
    const regToken = await idToken(REG);
    const admToken = await idToken(ADM);

    // Probe 1 — signed-OUT create, exact shape: SUCCEEDS.
    let r = await call('POST', `${FS_API}/error_reports`, null, baseDoc());
    check('1a signed-out create (exact shape)', r.status, 200);
    if (r.json?.name) created.push(r.json.name);
    const variant = baseDoc();
    variant.fields.operation = NL();
    variant.fields.recovered = S('pending');
    r = await call('POST', `${FS_API}/error_reports`, null, variant);
    check('1b signed-out create (operation null, recovered "pending")', r.status, 200);
    if (r.json?.name) created.push(r.json.name);

    // Probe 2 — malformed creates: DENIED.
    const extra = baseDoc(); extra.fields.debug = S('x');
    r = await call('POST', `${FS_API}/error_reports`, null, extra);
    check('2a malformed create (extra key)', r.status, 403);
    const tier3 = baseDoc(); tier3.fields.tier = I(3);
    r = await call('POST', `${FS_API}/error_reports`, null, tier3);
    check('2b malformed create (tier 3)', r.status, 403);
    const badSite = baseDoc(); badSite.fields.site = S('other-site');
    r = await call('POST', `${FS_API}/error_reports`, null, badSite);
    check('2c malformed create (wrong site)', r.status, 403);
    const missing = baseDoc(); delete missing.fields.page;
    r = await call('POST', `${FS_API}/error_reports`, null, missing);
    check('2d malformed create (missing key)', r.status, 403);
    const tierStr = baseDoc(); tierStr.fields.tier = S('1');
    r = await call('POST', `${FS_API}/error_reports`, null, tierStr);
    check('2e malformed create (tier as string)', r.status, 403);

    // Probe 3a — reads: signed-out and regular user DENIED.
    r = await call('GET', `${FS_API}/error_reports`, null);
    check('3a signed-out list error_reports', r.status, 403);
    if (created[0]) {
      const url = `https://firestore.googleapis.com/v1/${created[0]}`;
      r = await call('GET', url, regToken);
      check('3b regular user GET error_reports doc', r.status, 403);
      r = await call('GET', `${FS_API}/error_reports`, regToken);
      check('3c regular user LIST error_reports', r.status, 403);
      r = await call('DELETE', url, regToken);
      check('3d regular user DELETE error_reports doc', r.status, 403);
      r = await call('PATCH', url, null, { fields: { tier: I(2) } });
      check('3e signed-out UPDATE error_reports doc', r.status, 403);
      // Probe 3b — admin reads SUCCEED.
      r = await call('GET', url, admToken);
      check('3f admin GET error_reports doc', r.status, 200);
      r = await call('GET', `${FS_API}/error_reports`, admToken);
      check('3g admin LIST error_reports', r.status, 200);
      if (created[1]) {
        r = await call('DELETE', `https://firestore.googleapis.com/v1/${created[1]}`, admToken);
        check('3h admin DELETE error_reports doc', r.status, 200);
      }
    } else {
      fail('probe 3: no probe document was created, read probes skipped');
      failures++;
    }

    // Regression — pre-existing paths still deny unauthenticated access.
    for (const p of ['families/default/tasks', 'families/default/members', 'audit_logs', 'system_admins', 'global_config/system_defaults', 'section_access/probe@example.com']) {
      r = await call('GET', `${FS_API}/${p}`, null);
      check(`R unauthenticated GET ${p}`, r.status, 403);
    }
  } catch (e) {
    fail(`probe: exception: ${e.message}`);
    failures++;
  } finally {
    // Cleanup: probe docs (admin-token DELETE also exercises the delete
    // rule; Admin SDK is the backstop), the temporary seat, the users.
    let deleted = 0;
    try {
      const snap = await db.collection('error_reports').get();
      for (const d of snap.docs) {
        const op = d.get('operation');
        const code = d.get('code');
        if (code === 'probe/step1' || op === 'step1-probe' || code === 'probe/manual' || op === 'manual-probe') {
          await d.ref.delete();
          deleted++;
        }
      }
    } catch (e) { log(`cleanup: doc sweep error: ${e.message}`); }
    log(`cleanup: ${deleted} probe document(s) deleted via Admin SDK sweep (plus any already removed)`);
    try { await db.doc(`system_admins/${ADM}`).delete(); log('cleanup: temporary admin seat removed'); }
    catch (e) { log(`cleanup: seat removal error: ${e.message}`); }
    for (const uid of [REG, ADM]) {
      try { await auth.deleteUser(uid); } catch { /* already gone */ }
    }
    log('cleanup: throwaway auth users deleted');
  }
  if (failures > 0) process.exitCode = 1;
  log(`probe: ${failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)'}`);
}
