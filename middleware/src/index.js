// file: src/index.js
// path: ./src/index.js
//
// groups-update-2026-11-12: groups.* actions resolve against the
// server-side app-release group registry (MW_GROUP_REGISTRY) —
// four-group model, domain-group targets, release order, and the
// Nov 12, 2026 confirmation rules (simple one-click for ordinary
// person adds at the caller layer; Owners membership changes are
// MANUAL-ONLY per Andrew's Nov 12, 2026 decision (b) — see the
// Owners block in the groups handler).
// Prepared by Muse; deployed only by the owner-run update script
// in middleware/groups-update-2026-11-12/. The HTTP-500 error-builder
// defect is deliberately untouched (separate builder-exchange item).
//
// home-update-2026-11-13 (TWO change sets in this source, kept
// separate below and in the build report):
//   Change set 1 — NAMED AUTOMATIONS (spec:
//   named-automations-spec-2026-11-13.md, approved by Andrew
//   Nov 13, 2026). The middleware itself becomes the linked Smart
//   Home service: /home/auth + /home/token + /home/fulfill routes,
//   SYNC rendered dynamically from a D1 registry of named
//   automations (one virtual switch per name), registry-admin
//   actions (home.automations.*), and the home.automations.pulse
//   action implementing the spec §4 pulse protocol and the §5
//   honesty contract exactly. Deployed only by the owner-run
//   update script in middleware/home-update-2026-11-13/.
//   Change set 2 — ERROR-RESPONSE FIX (Middleware Exchange 3,
//   filed since the first build): the pre-envelope error paths
//   returned the bare error object instead of an HTTP Response,
//   so unauthenticated/malformed calls surfaced as HTTP 500.
//   They now return proper Responses with the intended status
//   codes (401 before any action parsing, 400 malformed, 404
//   unknown endpoint). No action behavior changes.

const ACTION_CATALOG = {
  // --- WAVE 1A ACTIONS ---
  "groups.members.add": { class: "mutation", async: false }, // Owners-group targets return needs_owner/manual_only in the handler — Owners changes are manual per Andrew's Nov 12, 2026 decision (groups-update-2026-11-12)
  "groups.members.remove": { class: "mutation", async: false }, // F1: implemented below
  "groups.get": { class: "read", async: false },
  "play.apps.create": { class: "consequential", async: true },
  "jobs.get": { class: "read", async: false }, // F1: implemented below
  
  // --- UNRATIFIED JUDGMENT CALLS (§1.8) EXPLICITLY ENCODED HERE ---
  "releases.internal.publish": { class: "consequential", async: true }, // (1) Internal-track releases block
  "iam.policy.set": { class: "consequential", async: false },           // (2) IAM policy caution
  "gcp.projects.create": { class: "consequential", async: true },       // (3) Project creation stops
  "contacts.merge": { class: "mutation", async: false },                // (4) Contact-merge confidence bar
  "calendar.events.delete": { class: "mutation", async: false },       // (5) Shared-calendar deletes

  // --- NAMED AUTOMATIONS (home-update-2026-11-13, change set 1) ---
  // The registry is the allowlist (spec §2): only listed AND
  // enabled automations can be pulsed. Triggering a named
  // automation is Andrew-authorized by the spec, so the pulse is
  // mutation class — it does NOT ride the §3.7 consequential
  // preview machinery, and none of the five §1.8 judgment calls
  // covers it.
  "home.automations.list": { class: "read", async: false },
  "home.automations.upsert": { class: "mutation", async: false },
  "home.automations.set_enabled": { class: "mutation", async: false },
  "home.automations.remove": { class: "mutation", async: false },
  "home.automations.pulse": { class: "mutation", async: false }
};

export default {
  async fetch(request, env, ctx) {
    const startTime = Date.now();
    let auditId = `mw-${new Date().toISOString().replace(/[-:T.]/g, "").slice(0,14)}-${Math.random().toString(36).substring(2,6)}`;
    
    // 1. Health & Capabilities Check
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/v1/health") return new Response(JSON.stringify({ status: "ok" }), { status: 200 });

    // 1b. Smart Home routes (home-update-2026-11-13, change set 1).
    // Google calls these, not Muse: they are gated by the link
    // code at authorize time and by Worker-issued tokens after,
    // never by the Muse bearer token — so they route BEFORE the
    // bearer check below.
    if (url.pathname === "/home/auth" || url.pathname === "/home/auth/callback" || url.pathname === "/home/token" || url.pathname === "/home/fulfill") {
      return handleHome(request, env, ctx, url.pathname);
    }

    // 2. Authentication (§3.2)
    // home-update-2026-11-13, change set 2: errorHttpResponse wraps
    // the error payload in a real HTTP Response — the bare object
    // this used to return is what surfaced as HTTP 500.
    const authHeader = request.headers.get("Authorization");
    if (!authHeader || authHeader !== `Bearer ${env.MUSE_BEARER_TOKEN}`) {
      return errorHttpResponse("unauthorized", false, "Invalid or missing token", "middleware", startTime, auditId, 401);
    }

    if (request.method === "GET" && url.pathname === "/v1/capabilities") {
      return new Response(JSON.stringify({
        service: "middleware", protocol_version: 1,
        actions: Object.entries(ACTION_CATALOG).map(([act, meta]) => ({ action: act, ...meta })),
        passthrough_allowlist: [] 
      }), { status: 200 });
    }

    if (request.method !== "POST" || url.pathname !== "/v1/invoke") {
      return errorHttpResponse("validation", false, "Invalid endpoint", "middleware", startTime, auditId, 404);
    }

    // 3. Parse Envelope (§3.3)
    let body;
    try { body = await request.json(); } catch (e) {
      return errorHttpResponse("validation", false, "Malformed JSON", "middleware", startTime, auditId, 400);
    }

    const { request_id, action, mode, params, context, approval } = body;
    if (!request_id || !action || !mode || !context?.reason) {
      return errorHttpResponse("validation", false, "Missing required envelope fields", "middleware", startTime, auditId, 400);
    }

    if (!ACTION_CATALOG[action]) {
      return errorHttpResponse("unknown_action", false, `Action ${action} not in catalog`, "middleware", startTime, auditId, 400);
    }

    // 4. Idempotency Check (D1 - Ratified) (§3.4)
    const ledgerCheck = await env.DB.prepare("SELECT * FROM ledger WHERE request_id = ?").bind(request_id).first();
    if (ledgerCheck) {
      if (ledgerCheck.status === "running") {
        return new Response(JSON.stringify(
          buildResponse(request_id, auditId, "in_progress", action, { job_id: request_id, poll_after_ms: 5000 }, null, startTime)
        ), { status: 200, headers: { "Content-Type": "application/json" } });
      }
      return new Response(ledgerCheck.response_json, { status: 200, headers: { "Content-Type": "application/json" } });
    }

    // Mark as running
    await env.DB.prepare("INSERT INTO ledger (request_id, status) VALUES (?, ?)").bind(request_id, "running").run();

    // 5. Execution & Routing
    let finalResponse;
    try {
      finalResponse = await routeAction(action, mode, params, context, approval, env, request_id, auditId, startTime, ctx);
    } catch (err) {
      finalResponse = errorResponse("internal", true, err.message, "middleware", startTime, auditId, 500, request_id);
    }

    // home-update-2026-11-13, change set 1: a handler may pin the
    // outer HTTP status via an `http_status` hint on its response
    // object (the pulse action uses this for the spec §5 contract:
    // 502/504 only when Home Graph rejects the reportState call).
    // The hint is consumed here and never stored or serialized.
    let outerStatus = 200;
    if (finalResponse && typeof finalResponse.http_status === "number") {
      outerStatus = finalResponse.http_status;
      delete finalResponse.http_status;
    }

    // 6. Finalize Ledger & Audit
    await env.DB.prepare("UPDATE ledger SET status = ?, response_json = ? WHERE request_id = ?")
      .bind(finalResponse.status, JSON.stringify(finalResponse), request_id).run();

    await env.DB.prepare("INSERT INTO audit (audit_id, request_id, caller, action, reason) VALUES (?, ?, ?, ?, ?)")
      .bind(auditId, request_id, "muse", action, context.reason).run();

    return new Response(JSON.stringify(finalResponse), { status: outerStatus, headers: { "Content-Type": "application/json" } });
  }
};

async function routeAction(action, mode, params, context, approval, env, request_id, auditId, startTime, ctx) {
  const meta = ACTION_CATALOG[action];

  // Consequential Preview Guard (§3.7) (Ratified - stored server side)
  if (meta.class === "consequential" && mode === "execute") {
    const previewId = `prv-${crypto.randomUUID()}`;
    const previewData = { change: `Preview generated for ${action}`, params };
    await env.DB.prepare("INSERT INTO previews (preview_id, action, payload_json, expires_at) VALUES (?, ?, ?, datetime('now', '+1 day'))")
      .bind(previewId, action, JSON.stringify(previewData)).run();
      
    return buildResponse(request_id, auditId, "needs_approval", action, { preview: previewData, preview_id: previewId }, null, startTime);
  }

  // F1: jobs.get Implementation
  if (action === "jobs.get") {
    if (!params.job_id) throw new Error("validation: job_id required");
    const jobRecord = await env.DB.prepare("SELECT request_id, status, response_json, created_at FROM ledger WHERE request_id = ?").bind(params.job_id).first();
    if (!jobRecord) throw new Error("validation: Job not found");
    const responsePayload = jobRecord.response_json ? JSON.parse(jobRecord.response_json) : { status: jobRecord.status };
    return buildResponse(request_id, auditId, "completed", action, { job_state: responsePayload }, null, startTime);
  }

  // Named Automations (home-update-2026-11-13, change set 1;
  // spec §§2/4/5). Handlers live in the Home section below.
  if (action.startsWith("home.automations.")) {
    return routeHomeAction(action, params || {}, env, request_id, auditId, startTime, ctx);
  }

  // App Creation (Owner Assisted - §1.3)
  if (action === "play.apps.create") {
    return buildResponse(request_id, auditId, "needs_owner", action, {
      owner_step: "Manually create app entry in Play Console. Reply to this payload with the assigned package_name.",
      prepared_defaults: { default_locale: "en-US", title: params.title }
    }, null, startTime);
  }

  // Google Groups Logic (§1.4)
  if (action.startsWith("groups.")) {
    if (!env.WORKSPACE_ADMIN_EMAIL) throw new Error("Server configuration error: WORKSPACE_ADMIN_EMAIL secret is missing.");

    // --- groups-update-2026-11-12: registry resolution + gates ---
    // The four app-release groups live in a server-side registry
    // (MW_GROUP_REGISTRY secret, set by the owner-run update script).
    // params.groupKey may be a registry key ("owners"), the consumer
    // @googlegroups.com address, or the domain address; it always
    // resolves to the group's DOMAIN address for the API call.
    // Consumer @googlegroups.com addresses are recorded as the
    // current/manual state only — Admin SDK + DWD cannot manage
    // consumer groups (Nov 11, 2026 live test), so the Worker never
    // calls them directly.
    const registry = loadGroupRegistry(env);
    const group = resolveGroup(registry, params.groupKey);
    if (!group) throw new Error(`validation: unknown group '${params.groupKey}' — not in the app-release group registry`);

    if (!group.domain_address) {
      // No domain group exists for this audience in the Workspace
      // plan (Family — tester-groups.json, Nov 12, 2026 note):
      // membership stays a manual Groups-UI step.
      return buildResponse(request_id, auditId, "needs_owner", action, {
        group: group.key,
        state: "manual_only",
        owner_step: `Group '${group.name}' has no domain group in the Workspace plan; manage its membership by hand in the Groups UI. The middleware does not call its consumer address (${group.consumer_address}).`
      }, null, startTime);
    }

    // OWNERS — MANUAL ONLY (Andrew's decision, Nov 12, 2026,
    // option (b), in his words: "Manual change and listen for
    // change artifacts and activate any next actions"). Owners
    // membership changes are made MANUALLY by Andrew in the Google
    // Groups UI; the middleware NEVER executes them, and the
    // approval-redemption protocol addition is NOT being built.
    // This replaces the earlier OWNERS GATE needs_approval preview
    // stop (the runbook rule (d) encoding); the §3.7 preview
    // machinery itself is untouched and still serves the
    // consequential actions. The middleware's role for Owners is
    // read-only witness: groups.get stays enabled for this group
    // so roster changes can be observed, surfaced, and their next
    // actions activated. Ordinary groups stay mutation class —
    // their confirmation is Andrew's one-click confirmation at
    // action time, enforced at the caller layer by his standing
    // click rule (recorded per group in the registry's
    // `confirmation` field).
    if (group.key === "owners" && (action === "groups.members.add" || action === "groups.members.remove") && mode === "execute") {
      return buildResponse(request_id, auditId, "needs_owner", action, {
        group: group.key,
        state: "manual_only",
        owner_step: `Owners-group membership changes are manual per Andrew's Nov 12, 2026 decision (option (b)): make the change by hand in the Google Groups UI. The middleware never executes Owners changes; it only witnesses them — groups.get on Owners stays enabled so the change can be observed and its next actions activated.`
      }, null, startTime);
    }

    const groupKey = group.domain_address;

    // F2: DWD Implementation with `sub` claim impersonating the workspace admin and strict scoping
    const scope = "https://www.googleapis.com/auth/admin.directory.group.member";
    const token = await getGoogleAccessToken(env.GCP_WORKSPACE_SA_KEY, scope, env.WORKSPACE_ADMIN_EMAIL);
    if (!token) throw new Error("Failed to generate Google Workspace DWD token");

    if (action === "groups.get") {
      const res = await fetch(`https://admin.googleapis.com/admin/directory/v1/groups/${groupKey}/members`, {
        headers: { Authorization: `Bearer ${token}` }
      });
      if (!res.ok) throw new Error(`Google API returned ${res.status}`);
      const data = await res.json();
      return buildResponse(request_id, auditId, "completed", action, { group: group.key }, data, startTime);
    }

    if (action === "groups.members.add") {
      if (!params.email) throw new Error("validation: Email required");
      const res = await fetch(`https://admin.googleapis.com/admin/directory/v1/groups/${groupKey}/members`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ email: params.email, role: "MEMBER" })
      });
      if (!res.ok) throw new Error(`Google API returned ${res.status}`);

      const evidenceRes = await fetch(`https://admin.googleapis.com/admin/directory/v1/groups/${groupKey}/members`, {
        headers: { Authorization: `Bearer ${token}` }
      });
      const evidence = await evidenceRes.json();
      return buildResponse(request_id, auditId, "completed", action, { added: params.email, group: group.key }, evidence, startTime);
    }

    // F1: groups.members.remove Implementation (Silent correction shape + read-back evidence)
    if (action === "groups.members.remove") {
      if (!params.email) throw new Error("validation: Email required");
      const res = await fetch(`https://admin.googleapis.com/admin/directory/v1/groups/${groupKey}/members/${params.email}`, {
        method: "DELETE",
        headers: { Authorization: `Bearer ${token}` }
      });
      // Treat 404 (already gone) as success for silent correction
      if (!res.ok && res.status !== 404) throw new Error(`Google API returned ${res.status}`);

      const evidenceRes = await fetch(`https://admin.googleapis.com/admin/directory/v1/groups/${groupKey}/members`, {
        headers: { Authorization: `Bearer ${token}` }
      });
      const evidence = await evidenceRes.json();
      return buildResponse(request_id, auditId, "completed", action, { removed: params.email, group: group.key }, evidence, startTime);
    }
  }

  throw new Error(`Action ${action} implemented but handler missing.`);
}

// App-release group registry (groups-update-2026-11-12). The registry
// JSON rides in the MW_GROUP_REGISTRY Worker secret, set by the
// owner-run update script — it is configuration (group names and
// addresses), carried in a secret only because that is the fleet's
// established owner-run config channel for this Worker.
function loadGroupRegistry(env) {
  if (!env.MW_GROUP_REGISTRY) throw new Error("Server configuration error: MW_GROUP_REGISTRY secret is missing — run the groups update (middleware/groups-update-2026-11-12).");
  let registry;
  try { registry = JSON.parse(env.MW_GROUP_REGISTRY); } catch (e) {
    throw new Error("Server configuration error: MW_GROUP_REGISTRY is not valid JSON.");
  }
  if (!registry || !Array.isArray(registry.groups)) throw new Error("Server configuration error: MW_GROUP_REGISTRY has no groups list.");
  return registry;
}

function resolveGroup(registry, groupKey) {
  if (!groupKey) throw new Error("validation: groupKey required");
  return registry.groups.find(g => g.key === groupKey || g.consumer_address === groupKey || g.domain_address === groupKey) || null;
}

function buildResponse(request_id, audit_id, status, action, result, evidence, startTime) {
  return {
    request_id, audit_id, status, action, result, evidence, error: null,
    duration_ms: Date.now() - startTime
  };
}

function errorResponse(kind, retryable, message, provider, startTime, audit_id, httpStatus = 200, request_id = "unknown") {
  return {
    request_id, audit_id, status: "failed", action: "unknown", result: null, evidence: null,
    error: { kind, retryable, message, provider, side_effects: "unknown", detail: {} },
    duration_ms: Date.now() - startTime
  };
}

// home-update-2026-11-13, change set 2 (error-response fix): the
// pre-envelope error paths (auth, routing, envelope parsing) must
// return real HTTP Responses carrying the intended status code.
// Returning the bare errorResponse object from fetch() is the
// defect that surfaced as HTTP 500. In-envelope action errors keep
// the existing protocol shape (errorResponse object, HTTP 200) —
// authenticated well-formed calls are unaffected by this fix.
function errorHttpResponse(kind, retryable, message, provider, startTime, audit_id, httpStatus, request_id = "unknown") {
  const payload = errorResponse(kind, retryable, message, provider, startTime, audit_id, httpStatus, request_id);
  return new Response(JSON.stringify(payload), { status: httpStatus, headers: { "Content-Type": "application/json" } });
}

// =====================================================================
// NAMED AUTOMATIONS + SMART HOME FULFILLMENT
// (home-update-2026-11-13, change set 1 — spec:
// named-automations-spec-2026-11-13.md)
//
// The middleware itself is the linked Smart Home service (§1):
//   GET/POST /home/auth    — account-linking page. Primary gate
//                            (spec §11, Nov 13): Google sign-in —
//                            only the HOME_ALLOWED_EMAIL account
//                            passes; any other signed-in account
//                            gets a dead-end page. Fallback gate:
//                            the link code (HOME_LINK_CODE secret;
//                            the value never appears in this repo).
//   GET      /home/auth/callback — Google sign-in return leg.
//   POST     /home/token   — authorization_code + refresh_token
//                            grants; tokens stored hash-only in D1.
//   POST     /home/fulfill — SYNC (rendered dynamically from the
//                            registry), QUERY, EXECUTE, DISCONNECT.
// One virtual switch per registry entry (§2/§3). Shapes follow the
// proven prototype on the text-bridge Worker (the [test] Family
// Board link), which stays live and untouched until migration
// completes (spec §8). Storage is this Worker's own D1
// (middleware-ledger): home_automations (the registry),
// home_links, home_tokens, home_pulses — created lazily with
// CREATE TABLE IF NOT EXISTS and also applied by the owner-run
// update script.
// The Home Graph service-account key rides in the
// GOOGLE_HOME_SA_JSON Worker secret (same secret NAME as on the
// text-bridge Worker; a separate deposit on this Worker — the
// value never passes through code, chat, or this repo).
// =====================================================================

const HOME_AGENT_USER_ID = "andrew"; // single-user service, as in the prototype
const HOME_LINK_CODE_SECRET = "HOME_LINK_CODE"; // env key name only
const HOMEGRAPH_SCOPE = "https://www.googleapis.com/auth/homegraph";
const HOMEGRAPH_REPORT_URL = "https://homegraph.googleapis.com/v1/devices:reportStateAndNotification";
const HOMEGRAPH_REQUEST_SYNC_URL = "https://homegraph.googleapis.com/v1/devices:requestSync";
const HOME_CODE_TTL_MS = 10 * 60 * 1000;
const HOME_ACCESS_TTL_MS = 3600 * 1000;
const HOME_PULSE_HOLD_MS = 1000; // spec §4 (200 ms risks dropped/coalesced edges)
const HOME_DEFAULT_COOLDOWN_SECONDS = 10; // spec §2
const HOME_REDIRECT_PREFIX = "https://oauth-redirect.googleusercontent.com/";
// Display name settled by Andrew (spec §9b, Nov 13): the service
// is "Andrew Google Bridge"; device names come from the registry's
// display_name values.
const HOME_SERVICE_LABEL = "Andrew Google Bridge";
// Sign-in gate (spec §11; signin-update-2026-11-13): env key
// NAMES only — the client secret
// value is deposited by the owner-run update script and never
// appears in this repo. The gate is active only when all three
// are set; otherwise /home/auth serves the link-code form.
const HOME_SIGNIN_CLIENT_ID_KEY = "HOME_SIGNIN_CLIENT_ID";
const HOME_SIGNIN_CLIENT_SECRET_KEY = "HOME_SIGNIN_CLIENT_SECRET";
const HOME_ALLOWED_EMAIL_KEY = "HOME_ALLOWED_EMAIL";
const GOOGLE_IDENTITY_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const GOOGLE_IDENTITY_TOKEN_URL = "https://oauth2.googleapis.com/token";
const GOOGLE_TOKENINFO_URL = "https://oauth2.googleapis.com/tokeninfo";
const HOME_DEVICE_MANUFACTURER = "middleware";

const HOME_SCHEMA = [
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

let homeSchemaReady = false;
async function ensureHomeSchema(env) {
  if (homeSchemaReady) return;
  for (const sql of HOME_SCHEMA) await env.DB.prepare(sql).run();
  homeSchemaReady = true;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function sha256Hex(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function b64urlEncode(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
function b64urlText(text) {
  return b64urlEncode(new TextEncoder().encode(text));
}

// --- Registry helpers -------------------------------------------------

function homeDeviceId(slug) {
  return `mw-automation-${slug}`;
}

function homeSlugOk(slug) {
  return typeof slug === "string" && /^[a-z0-9][a-z0-9-]{0,63}$/.test(slug);
}

function homeRowView(row) {
  if (!row) return null;
  return {
    slug: row.slug,
    device_id: row.device_id,
    display_name: row.display_name,
    active: row.active === 1,
    cooldown_seconds: row.cooldown_seconds,
    known_state: row.known_state,
    last_pulse_at: row.last_pulse_at || null,
    updated_at: row.updated_at,
  };
}

async function getAutomation(env, slug) {
  return env.DB.prepare("SELECT * FROM home_automations WHERE slug = ?").bind(slug).first();
}

async function listAutomations(env) {
  const res = await env.DB.prepare("SELECT * FROM home_automations ORDER BY slug").all();
  return (res.results || []).map(homeRowView);
}

async function setAutomationState(env, slug, knownState) {
  await env.DB.prepare("UPDATE home_automations SET known_state = ?, updated_at = CURRENT_TIMESTAMP WHERE slug = ?")
    .bind(knownState, slug).run();
}

// Home Graph error detail: status plus Google's own error
// status/message (never any credential material — Google error
// bodies describe the request, not the caller). Added Nov 13
// while diagnosing a bare homegraph_http_400 on requestSync:
// the status alone could not distinguish a wrong-project key
// from an unregistered agent user.
async function homegraphErrorDetail(res) {
  let suffix = "";
  try {
    const j = await res.json();
    const e = (j && j.error) || {};
    const parts = [e.status, e.message].filter((x) => typeof x === "string" && x);
    if (parts.length) suffix = `: ${parts.join(" — ").slice(0, 200)}`;
  } catch (_) { /* non-JSON error body: the status alone stands */ }
  return `homegraph_http_${res.status}${suffix}`;
}

// Automatic requestSync after any registry change (spec §2).
// Best-effort by design: the registry write is already durable;
// a sync failure is reported in the action result, never thrown.
async function requestHomeSync(env) {
  if (!env.GOOGLE_HOME_SA_JSON) return { request_sync: "skipped", reason: "sa_not_configured" };
  const link = await getHomeLink(env);
  if (!link || !link.linked_at) return { request_sync: "skipped", reason: "not_linked" };
  try {
    const token = await getHomeGraphToken(env);
    if (!token) return { request_sync: "failed", detail: "oauth_failed" };
    const res = await fetch(HOMEGRAPH_REQUEST_SYNC_URL, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ requestId: crypto.randomUUID(), agentUserId: HOME_AGENT_USER_ID, async: false }),
    });
    if (!res.ok) return { request_sync: "failed", detail: await homegraphErrorDetail(res) };
    return { request_sync: "requested" };
  } catch (_) {
    return { request_sync: "failed", detail: "fetch_failed" };
  }
}

// --- Link + token store (D1, hash-only tokens, prototype shapes) ------

async function getHomeLink(env) {
  return env.DB.prepare("SELECT * FROM home_links WHERE agent_user_id = ?").bind(HOME_AGENT_USER_ID).first();
}

function homeRandomToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function issueHomeToken(env, kind, ttlMs, extra) {
  const raw = homeRandomToken();
  const hash = await sha256Hex(raw);
  await env.DB.prepare("INSERT INTO home_tokens (token_hash, kind, agent_user_id, redirect_uri, expires_at) VALUES (?, ?, ?, ?, ?)")
    .bind(hash, kind, HOME_AGENT_USER_ID, (extra && extra.redirect_uri) || null,
      ttlMs ? new Date(Date.now() + ttlMs).toISOString() : null).run();
  return raw;
}

async function findHomeToken(env, kind, raw) {
  if (typeof raw !== "string" || !raw || raw.length > 512) return null;
  const hash = await sha256Hex(raw);
  const doc = await env.DB.prepare("SELECT * FROM home_tokens WHERE token_hash = ?").bind(hash).first();
  if (!doc || doc.kind !== kind) return null;
  if (doc.expires_at && Date.parse(doc.expires_at) <= Date.now()) return null;
  return doc;
}

async function deleteHomeToken(env, raw) {
  if (typeof raw !== "string" || !raw) return;
  const hash = await sha256Hex(raw);
  await env.DB.prepare("DELETE FROM home_tokens WHERE token_hash = ?").bind(hash).run();
}

// Resolves a presented link code to the agent identity, comparing
// hashes so neither value is ever logged or echoed.
async function resolveHomeLinkCode(env, presented) {
  if (typeof presented !== "string" || !presented || !env[HOME_LINK_CODE_SECRET]) return null;
  const [a, b] = await Promise.all([sha256Hex(presented), sha256Hex(env[HOME_LINK_CODE_SECRET])]);
  return a === b ? HOME_AGENT_USER_ID : null;
}

// --- Sign-in gate (spec §11) -------------------------------------------
// Active only when client id + client secret + allowed email are
// ALL configured; the signed-in email is compared and never stored.

function homeSigninConfigured(env) {
  return !!(env[HOME_SIGNIN_CLIENT_ID_KEY] && env[HOME_SIGNIN_CLIENT_SECRET_KEY] && env[HOME_ALLOWED_EMAIL_KEY]);
}

// Issues the Smart Home authorization code and returns the 302 back
// to Google — shared by the link-code POST and the sign-in callback.
async function homeIssueCodeRedirect(env, fields) {
  const code = await issueHomeToken(env, "code", HOME_CODE_TTL_MS, { redirect_uri: fields.redirect_uri });
  const sep = fields.redirect_uri.includes("?") ? "&" : "?";
  let location = `${fields.redirect_uri}${sep}code=${encodeURIComponent(code)}`;
  if (fields.state) location += `&state=${encodeURIComponent(fields.state)}`;
  return new Response(null, { status: 302, headers: { Location: location, "Cache-Control": "no-store" } });
}

function homeDeadEndPage() {
  // The exact dead end Andrew specified (same wording as the
  // Bridge and Home Helper gates): nothing else, no controls.
  return homeHtmlPage(200, `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Andrew Google Bridge</title></head>
<body style="font-family: sans-serif; max-width: 26em; margin: 3em auto; padding: 0 1em;">
<p>You can't use this. Bye.</p>
</body></html>`);
}

function homeFlowErrorPage(status, text) {
  return homeHtmlPage(status, `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Andrew Google Bridge</title></head>
<body style="font-family: sans-serif; max-width: 26em; margin: 3em auto; padding: 0 1em;">
<p>${homeEscapeHtml(text)}</p>
</body></html>`);
}

async function handleHomeSigninCallback(request, env, url) {
  if (request.method !== "GET") {
    return homeJson(405, { ok: false, error: "method_not_allowed" }, { Allow: "GET" });
  }
  if (!homeSigninConfigured(env)) {
    return homeFlowErrorPage(403, "Sign-in linking is not enabled on this server. Nothing was linked.");
  }
  const stateRaw = url.searchParams.get("state") || "";
  const code = url.searchParams.get("code") || "";
  const pending = stateRaw ? await findHomeToken(env, "signin", stateRaw) : null;
  if (url.searchParams.get("error") || !code || !pending) {
    if (pending) await deleteHomeToken(env, stateRaw);
    return homeFlowErrorPage(200, "Google sign-in did not finish, so nothing was linked. Start linking again from Google Home.");
  }
  let fields = null;
  try { fields = JSON.parse(pending.redirect_uri || ""); } catch (_) { fields = null; }
  // Single-use: the pending record is burned before the exchange.
  await deleteHomeToken(env, stateRaw);
  if (!fields || !String(fields.redirect_uri || "").startsWith(HOME_REDIRECT_PREFIX)) {
    return homeFlowErrorPage(400, "That sign-in return was not expected. Nothing was linked.");
  }
  const callbackUri = `${url.origin}/home/auth/callback`;
  let idToken = null;
  try {
    const res = await fetch(GOOGLE_IDENTITY_TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code,
        client_id: env[HOME_SIGNIN_CLIENT_ID_KEY],
        client_secret: env[HOME_SIGNIN_CLIENT_SECRET_KEY],
        redirect_uri: callbackUri,
        grant_type: "authorization_code",
      }),
    });
    if (res.ok) {
      const j = await res.json();
      if (j && typeof j.id_token === "string") idToken = j.id_token;
    }
  } catch (_) { /* handled below as a failed sign-in */ }
  if (!idToken) {
    return homeFlowErrorPage(200, "Google did not complete the sign-in, so nothing was linked. Start linking again from Google Home.");
  }
  let info = null;
  try {
    const res = await fetch(`${GOOGLE_TOKENINFO_URL}?id_token=${encodeURIComponent(idToken)}`);
    if (res.ok) info = await res.json();
  } catch (_) { /* handled below */ }
  const audOk = !!info && info.aud === env[HOME_SIGNIN_CLIENT_ID_KEY] &&
    (info.iss === "accounts.google.com" || info.iss === "https://accounts.google.com") &&
    typeof info.email === "string";
  if (!audOk) {
    return homeFlowErrorPage(200, "That sign-in could not be verified, so nothing was linked. Start linking again from Google Home.");
  }
  const verified = info.email_verified === "true" || info.email_verified === true;
  const emailOk = verified && info.email.toLowerCase() === String(env[HOME_ALLOWED_EMAIL_KEY]).toLowerCase();
  if (!emailOk) return homeDeadEndPage();
  console.log(`home link issued via google sign-in agent=${HOME_AGENT_USER_ID}`);
  return homeIssueCodeRedirect(env, fields);
}

// --- Home Graph client --------------------------------------------------

const homeGraphTokenCache = { token: null, expiresAtMs: 0 };

async function getHomeGraphToken(env) {
  if (homeGraphTokenCache.token && Date.now() < homeGraphTokenCache.expiresAtMs - 60000) {
    return homeGraphTokenCache.token;
  }
  if (!env.GOOGLE_HOME_SA_JSON) throw new Error("sa_missing");
  let sa;
  try { sa = JSON.parse(env.GOOGLE_HOME_SA_JSON); } catch (_) { throw new Error("sa_parse_failed"); }
  if (!sa.client_email || !sa.private_key) throw new Error("sa_parse_failed");
  const signingKey = await crypto.subtle.importKey(
    "pkcs8", parsePem(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]
  );
  const nowSec = Math.floor(Date.now() / 1000);
  const signingInput = `${b64urlText(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.${b64urlText(JSON.stringify({
    iss: sa.client_email, sub: sa.client_email, aud: "https://oauth2.googleapis.com/token",
    iat: nowSec, exp: nowSec + 3600, scope: HOMEGRAPH_SCOPE,
  }))}`;
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", signingKey, new TextEncoder().encode(signingInput));
  const assertion = `${signingInput}.${b64urlEncode(signature)}`;
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${encodeURIComponent(assertion)}`,
  });
  if (!res.ok) throw new Error("oauth_exchange_failed");
  const data = await res.json();
  if (!data.access_token) throw new Error("oauth_exchange_failed");
  homeGraphTokenCache.token = data.access_token;
  homeGraphTokenCache.expiresAtMs = Date.now() + (data.expires_in || 3600) * 1000;
  return homeGraphTokenCache.token;
}

// One reportStateAndNotification call for one device. Never throws.
// Failure classes follow the spec §5 contract: an HTTP rejection by
// Home Graph is 502-class; a transport failure reaching it is
// 504-class.
async function reportHomeState(env, deviceId, on) {
  let token;
  try {
    token = await getHomeGraphToken(env);
  } catch (err) {
    return { ok: false, detail: `oauth_${err.message || "failed"}`, httpStatus: 502 };
  }
  let res;
  try {
    res = await fetch(HOMEGRAPH_REPORT_URL, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        requestId: crypto.randomUUID(),
        agentUserId: HOME_AGENT_USER_ID,
        payload: { devices: { states: { [deviceId]: { on } } } },
      }),
    });
  } catch (_) {
    return { ok: false, detail: "homegraph_fetch_failed", httpStatus: 504 };
  }
  if (!res.ok) return { ok: false, detail: await homegraphErrorDetail(res), httpStatus: 502 };
  return { ok: true };
}

// --- Registry-admin + pulse actions -------------------------------------

async function routeHomeAction(action, params, env, request_id, auditId, startTime, ctx) {
  await ensureHomeSchema(env);

  if (action === "home.automations.list") {
    return buildResponse(request_id, auditId, "completed", action,
      { automations: await listAutomations(env) }, null, startTime);
  }

  if (action === "home.automations.upsert") {
    const slug = params.slug;
    if (!homeSlugOk(slug)) throw new Error("validation: slug required (lowercase letters, digits, dashes; max 64)");
    const displayName = typeof params.display_name === "string" ? params.display_name.trim() : "";
    if (!displayName || displayName.length > 80) throw new Error("validation: display_name required (max 80 chars)");
    let cooldown = params.cooldown_seconds === undefined ? HOME_DEFAULT_COOLDOWN_SECONDS : Number(params.cooldown_seconds);
    if (!Number.isInteger(cooldown) || cooldown < 0 || cooldown > 3600) throw new Error("validation: cooldown_seconds must be an integer 0..3600");
    const existing = await getAutomation(env, slug);
    // Explicit enablement (spec §2): a new entry starts INACTIVE
    // unless this call itself sets active — listing a name never
    // silently makes it triggerable.
    const active = params.active === undefined
      ? (existing ? existing.active : 0)
      : (params.active === true || params.active === 1 ? 1 : 0);
    await env.DB.prepare(
      `INSERT INTO home_automations (slug, device_id, display_name, active, cooldown_seconds, known_state, updated_at)
       VALUES (?, ?, ?, ?, ?, 'unknown', CURRENT_TIMESTAMP)
       ON CONFLICT(slug) DO UPDATE SET display_name = excluded.display_name,
         active = excluded.active, cooldown_seconds = excluded.cooldown_seconds,
         updated_at = CURRENT_TIMESTAMP`
    ).bind(slug, homeDeviceId(slug), displayName, active, cooldown).run();
    const sync = await requestHomeSync(env);
    return buildResponse(request_id, auditId, "completed", action,
      { automation: homeRowView(await getAutomation(env, slug)), ...sync }, null, startTime);
  }

  if (action === "home.automations.set_enabled") {
    const slug = params.slug;
    if (!homeSlugOk(slug)) throw new Error("validation: slug required");
    const enabled = params.enabled !== undefined ? params.enabled : params.active;
    if (typeof enabled !== "boolean") throw new Error("validation: enabled (boolean) required");
    const existing = await getAutomation(env, slug);
    if (!existing) {
      return buildResponse(request_id, auditId, "refused", action,
        { reason: "not_in_registry", slug }, null, startTime);
    }
    await env.DB.prepare("UPDATE home_automations SET active = ?, updated_at = CURRENT_TIMESTAMP WHERE slug = ?")
      .bind(enabled ? 1 : 0, slug).run();
    const sync = await requestHomeSync(env);
    return buildResponse(request_id, auditId, "completed", action,
      { automation: homeRowView(await getAutomation(env, slug)), ...sync }, null, startTime);
  }

  if (action === "home.automations.remove") {
    const slug = params.slug;
    if (!homeSlugOk(slug)) throw new Error("validation: slug required");
    const existing = await getAutomation(env, slug);
    if (!existing) {
      return buildResponse(request_id, auditId, "refused", action,
        { reason: "not_in_registry", slug }, null, startTime);
    }
    await env.DB.prepare("DELETE FROM home_automations WHERE slug = ?").bind(slug).run();
    const sync = await requestHomeSync(env);
    return buildResponse(request_id, auditId, "completed", action,
      { removed: slug, ...sync }, null, startTime);
  }

  if (action === "home.automations.pulse") {
    return pulseAutomation(params, env, request_id, auditId, startTime, ctx);
  }

  throw new Error(`Action ${action} implemented but handler missing.`);
}

// The pulse (spec §4) under the §5 honesty contract. The result
// reports the pipeline only: TRIGGER_DISPATCHED means Home Graph
// accepted the on-report — whether the automation fired or any
// device acted is UNOBSERVABLE and is stated as such.
async function pulseAutomation(params, env, request_id, auditId, startTime, ctx) {
  const action = "home.automations.pulse";
  const slug = params.slug;
  if (!homeSlugOk(slug)) throw new Error("validation: slug required");
  const pulseKey = typeof params.idempotency_key === "string" && params.idempotency_key
    ? params.idempotency_key : request_id;

  // Idempotency (spec §4): a repeated key returns the original
  // record — no second pulse is ever sent for the same key.
  const prior = await env.DB.prepare("SELECT * FROM home_pulses WHERE pulse_key = ?").bind(pulseKey).first();
  if (prior) {
    const result = prior.result_json ? JSON.parse(prior.result_json) : { pipeline_stage: prior.outcome };
    result.deduplicated = true;
    const resp = buildResponse(request_id, auditId,
      prior.outcome === "TRIGGER_DISPATCHED" ? "completed" : "failed",
      action, result, null, startTime);
    if (prior.http_status) resp.http_status = prior.http_status;
    return resp;
  }

  const recordPulse = async (outcome, result, httpStatus) => {
    await env.DB.prepare(
      "INSERT INTO home_pulses (pulse_key, slug, request_id, outcome, detail, result_json, http_status) VALUES (?, ?, ?, ?, ?, ?, ?)"
    ).bind(pulseKey, slug, request_id, outcome,
      result && result.detail ? String(result.detail) : null,
      result ? JSON.stringify(result) : null, httpStatus || null).run();
  };

  // Registry-only + enabled-only (spec §2): anything else is
  // refused before any Google call is made.
  const row = await getAutomation(env, slug);
  if (!row) {
    return buildResponse(request_id, auditId, "refused", action,
      { reason: "not_in_registry", slug }, null, startTime);
  }
  if (row.active !== 1) {
    return buildResponse(request_id, auditId, "refused", action,
      { reason: "not_enabled", slug }, null, startTime);
  }
  if (!env.GOOGLE_HOME_SA_JSON) {
    return buildResponse(request_id, auditId, "needs_owner", action, {
      state: "sa_not_configured",
      owner_step: "Deposit the Home Graph service-account JSON as the GOOGLE_HOME_SA_JSON secret on the andrew-middleware Worker (owner-run deposit step in the home-update-2026-11-13 report; the value never passes through chat or Muse).",
    }, null, startTime);
  }
  const link = await getHomeLink(env);
  if (!link || !link.linked_at) {
    return buildResponse(request_id, auditId, "needs_owner", action, {
      state: "not_linked",
      owner_step: "Link the middleware service in Google Home first (the /home/auth page, gated by the link code). No pulse is possible until the link exists.",
    }, null, startTime);
  }

  // Per-automation cooldown guard (spec §2, default 10 s).
  if (row.last_pulse_at) {
    const elapsedMs = Date.now() - Date.parse(row.last_pulse_at);
    const cooldownMs = (row.cooldown_seconds || 0) * 1000;
    if (elapsedMs < cooldownMs) {
      return buildResponse(request_id, auditId, "refused", action, {
        reason: "cooldown", slug,
        retry_after_seconds: Math.ceil((cooldownMs - elapsedMs) / 1000),
      }, null, startTime);
    }
  }

  const triggerFailed = async (failure) => {
    const result = {
      pipeline_stage: "TRIGGER_FAILED",
      verification: { homegraph_report_accepted: false, automation_fired: "UNOBSERVABLE", target_device_acted: "UNOBSERVABLE" },
      slug, device_id: row.device_id, detail: failure.detail,
    };
    await recordPulse("TRIGGER_FAILED", result, failure.httpStatus);
    const resp = buildResponse(request_id, auditId, "failed", action, result, null, startTime);
    resp.http_status = failure.httpStatus; // 502/504 per spec §5
    return resp;
  };

  // Self-healing pre-flight (spec §4): if the known state is ON or
  // unknown, an out-of-band off + 500 ms wait precedes the pulse,
  // so the on-edge is real.
  if (row.known_state !== "off") {
    const pre = await reportHomeState(env, row.device_id, false);
    if (!pre.ok) { await setAutomationState(env, slug, "unknown"); return triggerFailed(pre); }
    await setAutomationState(env, slug, "off");
    await sleep(500);
  }

  const onRes = await reportHomeState(env, row.device_id, true);
  if (!onRes.ok) { await setAutomationState(env, slug, "unknown"); return triggerFailed(onRes); }
  await env.DB.prepare("UPDATE home_automations SET known_state = 'on', last_pulse_at = ?, updated_at = CURRENT_TIMESTAMP WHERE slug = ?")
    .bind(new Date().toISOString(), slug).run();

  const result = {
    pipeline_stage: "TRIGGER_DISPATCHED",
    verification: { homegraph_report_accepted: true, automation_fired: "UNOBSERVABLE", target_device_acted: "UNOBSERVABLE" },
    slug, device_id: row.device_id, idempotency_key: pulseKey, deduplicated: false,
  };
  await recordPulse("TRIGGER_DISPATCHED", result, null);

  // Hold 1,000 ms, then reset off to re-arm the edge (spec §4).
  await sleep(HOME_PULSE_HOLD_MS);
  const offRes = await reportHomeState(env, row.device_id, false);
  if (offRes.ok) {
    await setAutomationState(env, slug, "off");
  } else {
    // Reset retries ×2 with 500 ms backoff in waitUntil; exhausted
    // resets are flagged in D1 as STUCK_ON_RESET_FAILED (spec §4).
    const retryReset = async () => {
      for (let attempt = 0; attempt < 2; attempt++) {
        await sleep(500);
        const again = await reportHomeState(env, row.device_id, false);
        if (again.ok) { await setAutomationState(env, slug, "off"); return; }
      }
      await env.DB.prepare("UPDATE home_pulses SET outcome = 'STUCK_ON_RESET_FAILED', detail = ? WHERE pulse_key = ?")
        .bind(offRes.detail, pulseKey).run();
      await env.DB.prepare("INSERT INTO audit (audit_id, request_id, caller, action, reason) VALUES (?, ?, ?, ?, ?)")
        .bind(`pulse-${pulseKey}`, request_id, "middleware", "home.automations.pulse",
          `Reset-off exhausted retries for slug '${slug}': STUCK_ON_RESET_FAILED (${offRes.detail})`).run();
    };
    if (ctx && typeof ctx.waitUntil === "function") ctx.waitUntil(retryReset());
    else await retryReset();
  }

  return buildResponse(request_id, auditId, "completed", action, result, null, startTime);
}

// --- Smart Home HTTP routes (auth / token / fulfill) --------------------

function homeHtmlPage(status, bodyHtml) {
  return new Response(bodyHtml, {
    status,
    headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" },
  });
}

function homeJson(status, obj, extraHeaders) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json", ...(extraHeaders || {}) },
  });
}

function homeEscapeHtml(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function homeAuthPage(fields, errorLine) {
  const hidden = ["redirect_uri", "state", "client_id"]
    .map((k) => `<input type="hidden" name="${k}" value="${homeEscapeHtml(fields[k] || "")}">`)
    .join("\n      ");
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Link ${HOME_SERVICE_LABEL}</title></head>
<body style="font-family: sans-serif; max-width: 26em; margin: 3em auto; padding: 0 1em;">
<h1 style="font-size: 1.3em;">Link ${HOME_SERVICE_LABEL}</h1>
<p>This links your Google Home to ${HOME_SERVICE_LABEL} — virtual
on/off switches, one per named automation you have enabled, that
your own Google Home automations can use as starters. Nothing else
is shared: no automation content, no device data.</p>
${errorLine ? `<p style="color: #b00020;">${homeEscapeHtml(errorLine)}</p>` : ""}
<form method="POST" action="/home/auth">
      ${hidden}
<p><label>Link code<br>
<input type="password" name="link_code" autocomplete="off"
  style="font-size: 1.1em; padding: 0.4em; width: 100%;"></label></p>
<p><button type="submit" style="font-size: 1.1em; padding: 0.5em 1.2em;">
Link</button></p>
</form>
</body></html>`;
}

async function handleHome(request, env, ctx, path) {
  const url = new URL(request.url);
  try {
    await ensureHomeSchema(env);

    if (path === "/home/auth/callback") {
      return await handleHomeSigninCallback(request, env, url);
    }

    if (path === "/home/auth") {
      if (!env[HOME_LINK_CODE_SECRET] && !homeSigninConfigured(env)) {
        return homeHtmlPage(403, `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Linking disabled</title></head>
<body style="font-family: sans-serif; max-width: 26em; margin: 3em auto; padding: 0 1em;">
<h1 style="font-size: 1.3em;">Linking is not enabled</h1>
<p>Account linking for this service has not been switched on on
this server yet. Nothing was linked.</p>
</body></html>`);
      }
      if (request.method === "GET") {
        const fields = {
          redirect_uri: url.searchParams.get("redirect_uri") || "",
          state: url.searchParams.get("state") || "",
          client_id: url.searchParams.get("client_id") || "",
        };
        if (!fields.redirect_uri.startsWith(HOME_REDIRECT_PREFIX)) {
          return homeHtmlPage(400,
            "<p>Missing or unexpected redirect address — linking can only return to Google. Nothing was linked.</p>");
        }
        // Sign-in gate (spec §11): when configured, linking starts
        // with Google sign-in; ?method=code is the explicit fallback.
        if (homeSigninConfigured(env) && url.searchParams.get("method") !== "code") {
          const state = await issueHomeToken(env, "signin", HOME_CODE_TTL_MS, {
            redirect_uri: JSON.stringify(fields),
          });
          const authUrl = new URL(GOOGLE_IDENTITY_AUTH_URL);
          authUrl.searchParams.set("client_id", env[HOME_SIGNIN_CLIENT_ID_KEY]);
          authUrl.searchParams.set("redirect_uri", `${url.origin}/home/auth/callback`);
          authUrl.searchParams.set("response_type", "code");
          authUrl.searchParams.set("scope", "openid email");
          authUrl.searchParams.set("state", state);
          authUrl.searchParams.set("prompt", "select_account");
          return new Response(null, {
            status: 302,
            headers: { Location: authUrl.toString(), "Cache-Control": "no-store" },
          });
        }
        return homeHtmlPage(200, homeAuthPage(fields, null));
      }
      if (request.method !== "POST") {
        return homeJson(405, { ok: false, error: "method_not_allowed" }, { Allow: "GET, POST" });
      }
      const form = await request.formData();
      const fields = {
        redirect_uri: String(form.get("redirect_uri") || ""),
        state: String(form.get("state") || ""),
        client_id: String(form.get("client_id") || ""),
      };
      if (!fields.redirect_uri.startsWith(HOME_REDIRECT_PREFIX)) {
        return homeHtmlPage(400,
          "<p>Missing or unexpected redirect address — linking can only return to Google. Nothing was linked.</p>");
      }
      const agentUserId = await resolveHomeLinkCode(env, String(form.get("link_code") || ""));
      if (!agentUserId) {
        return homeHtmlPage(200, homeAuthPage(fields, "That link code did not match. Nothing was linked."));
      }
      console.log(`home link code issued agent=${agentUserId}`);
      return homeIssueCodeRedirect(env, fields);
    }

    if (path === "/home/token") {
      if (request.method !== "POST") {
        return homeJson(405, { ok: false, error: "method_not_allowed" }, { Allow: "POST" });
      }
      let form;
      try {
        form = await request.formData();
      } catch (_) {
        try { form = new URLSearchParams(await request.text()); }
        catch (_) { return homeJson(400, { error: "invalid_request" }); }
      }
      const get = (k) => {
        const v = typeof form.get === "function" ? form.get(k) : null;
        return v == null ? "" : String(v);
      };
      const grantType = get("grant_type");
      if (grantType === "authorization_code") {
        const codeRaw = get("code");
        const tok = await findHomeToken(env, "code", codeRaw);
        if (!tok) return homeJson(400, { error: "invalid_grant" });
        const presentedRedirect = get("redirect_uri");
        if (presentedRedirect && tok.redirect_uri && presentedRedirect !== tok.redirect_uri) {
          return homeJson(400, { error: "invalid_grant" });
        }
        // Single-use: the code is burned before tokens are issued.
        await deleteHomeToken(env, codeRaw);
        const existing = await getHomeLink(env);
        const now = new Date().toISOString();
        await env.DB.prepare(
          `INSERT INTO home_links (agent_user_id, linked_at, disconnected_at, updated_at) VALUES (?, ?, NULL, ?)
           ON CONFLICT(agent_user_id) DO UPDATE SET linked_at = COALESCE(home_links.linked_at, excluded.linked_at),
             disconnected_at = NULL, updated_at = excluded.updated_at`
        ).bind(HOME_AGENT_USER_ID, now, now).run();
        const accessToken = await issueHomeToken(env, "access", HOME_ACCESS_TTL_MS);
        const refreshToken = await issueHomeToken(env, "refresh", null);
        console.log(`home account linked agent=${HOME_AGENT_USER_ID} (previously linked: ${!!(existing && existing.linked_at)})`);
        return homeJson(200, {
          access_token: accessToken,
          token_type: "Bearer",
          refresh_token: refreshToken,
          expires_in: Math.floor(HOME_ACCESS_TTL_MS / 1000),
        });
      }
      if (grantType === "refresh_token") {
        const tok = await findHomeToken(env, "refresh", get("refresh_token"));
        if (!tok) return homeJson(400, { error: "invalid_grant" });
        // A disconnected link revokes its refresh tokens too.
        const linkNow = await getHomeLink(env);
        if (!linkNow || !linkNow.linked_at) return homeJson(400, { error: "invalid_grant" });
        // Refresh tokens are long-lived and NOT rotated (prototype
        // lesson: a refresh path that drops the grant silently
        // unlinks the service).
        const accessToken = await issueHomeToken(env, "access", HOME_ACCESS_TTL_MS);
        return homeJson(200, {
          access_token: accessToken,
          token_type: "Bearer",
          expires_in: Math.floor(HOME_ACCESS_TTL_MS / 1000),
        });
      }
      return homeJson(400, { error: "unsupported_grant_type" });
    }

    if (path === "/home/fulfill") {
      if (request.method !== "POST") {
        return homeJson(405, { ok: false, error: "method_not_allowed" }, { Allow: "POST" });
      }
      const auth = request.headers.get("Authorization") || "";
      const presented = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length) : "";
      const tok = await findHomeToken(env, "access", presented);
      if (!tok) return homeJson(401, { error: "unauthorized" });
      let body;
      try { body = JSON.parse(await request.text()); }
      catch (_) { return homeJson(400, { error: "bad_json" }); }
      const requestId = body && typeof body.requestId === "string" ? body.requestId : "";
      const inputs = body && Array.isArray(body.inputs) ? body.inputs : [];
      const intent = inputs.length && inputs[0] ? inputs[0].intent : "";
      const link = await getHomeLink(env);
      // A live link record is required for every intent except
      // DISCONNECT (which is what revokes it).
      if (intent !== "action.devices.DISCONNECT" && (!link || !link.linked_at)) {
        return homeJson(401, { error: "unauthorized" });
      }

      if (intent === "action.devices.DISCONNECT") {
        // Revocation is by link state: fulfillment auth and the
        // refresh grant both require a LIVE link record, so
        // clearing linked_at revokes every outstanding token.
        try {
          await env.DB.prepare("UPDATE home_links SET linked_at = NULL, disconnected_at = ?, updated_at = ? WHERE agent_user_id = ?")
            .bind(new Date().toISOString(), new Date().toISOString(), HOME_AGENT_USER_ID).run();
        } catch (_) { /* disconnect is best-effort */ }
        console.log(`home disconnected agent=${HOME_AGENT_USER_ID}`);
        return homeJson(200, { requestId });
      }

      if (intent === "action.devices.SYNC") {
        // SYNC is rendered DYNAMICALLY from the registry (spec
        // §3): one virtual switch per registry entry.
        const rows = await env.DB.prepare("SELECT * FROM home_automations ORDER BY slug").all();
        const devices = (rows.results || []).map((row) => ({
          id: row.device_id,
          type: "action.devices.types.SWITCH",
          traits: ["action.devices.traits.OnOff"],
          name: {
            defaultNames: [row.display_name],
            name: row.display_name,
            nicknames: [row.display_name],
          },
          willReportState: true,
          deviceInfo: {
            manufacturer: HOME_DEVICE_MANUFACTURER,
            model: "virtual-switch-1",
            hwVersion: "1.0",
            swVersion: "1.0",
          },
        }));
        return homeJson(200, { requestId, payload: { agentUserId: HOME_AGENT_USER_ID, devices } });
      }

      if (intent === "action.devices.QUERY") {
        const asked = inputs[0] && inputs[0].payload && Array.isArray(inputs[0].payload.devices)
          ? inputs[0].payload.devices : [];
        const rows = await env.DB.prepare("SELECT * FROM home_automations").all();
        const byDevice = new Map((rows.results || []).map((r) => [r.device_id, r]));
        const devices = {};
        const answer = (id) => {
          const row = byDevice.get(id);
          devices[id] = row
            ? { status: "SUCCESS", online: true, on: row.known_state === "on" }
            : { status: "ERROR", errorCode: "deviceNotFound" };
        };
        if (asked.length) {
          for (const d of asked) { if (d && typeof d.id === "string") answer(d.id); }
        } else {
          for (const id of byDevice.keys()) answer(id);
        }
        return homeJson(200, { requestId, payload: { devices } });
      }

      if (intent === "action.devices.EXECUTE") {
        // These are trigger devices: EXECUTE mirrors the commanded
        // state into the registry. When Andrew fires one of his
        // own automations, the resulting state report lands here
        // too — per spec §6 it is LOGGED for completeness (audit
        // row, caller "google-home") and nothing is done with it.
        const commandsIn = inputs[0] && inputs[0].payload && Array.isArray(inputs[0].payload.commands)
          ? inputs[0].payload.commands : [];
        const results = [];
        for (const cmd of commandsIn) {
          const ids = cmd && Array.isArray(cmd.devices)
            ? cmd.devices.map((d) => d && d.id).filter(Boolean) : [];
          const execs = cmd && Array.isArray(cmd.execution) ? cmd.execution : [];
          for (const ex of execs) {
            if (!ex || ex.command !== "action.devices.commands.OnOff") {
              results.push({ ids, status: "ERROR", errorCode: "notSupported" });
              continue;
            }
            const newOn = !!(ex.params && ex.params.on === true);
            const known = [];
            for (const id of ids) {
              const row = await env.DB.prepare("SELECT * FROM home_automations WHERE device_id = ?").bind(id).first();
              if (!row) continue;
              known.push(id);
              await setAutomationState(env, row.slug, newOn ? "on" : "off");
              try {
                await env.DB.prepare("INSERT INTO audit (audit_id, request_id, caller, action, reason) VALUES (?, ?, ?, ?, ?)")
                  .bind(`obs-${Date.now()}-${Math.random().toString(36).substring(2, 8)}`, requestId || "fulfill",
                    "google-home", "home.automations.observed",
                    `State report for '${row.slug}' via EXECUTE (on=${newOn}); logged for completeness per spec §6, no action taken`).run();
              } catch (_) { /* observability only */ }
            }
            if (!known.length) {
              results.push({ ids, status: "ERROR", errorCode: "deviceNotFound" });
            } else {
              results.push({ ids: known, status: "SUCCESS", states: { online: true, on: newOn } });
            }
          }
        }
        return homeJson(200, { requestId, payload: { commands: results } });
      }

      return homeJson(200, { requestId, payload: { errorCode: "notSupported" } });
    }

    return homeJson(404, { ok: false, error: "not_found" });
  } catch (err) {
    console.log(`home ${path} FAILED class=${err && err.message ? err.message : "unknown"}`);
    return homeJson(502, { ok: false, error: "storage_unavailable" });
  }
}

// Lightweight JWT Signer for Service Accounts
async function getGoogleAccessToken(saKeyJson, scope, impersonatedSub) {
  const credentials = JSON.parse(saKeyJson);
  const header = btoa(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const iat = Math.floor(Date.now() / 1000);
  
  // F2: Adding the `sub` claim to properly enforce DWD
  const claimPayload = {
    iss: credentials.client_email,
    sub: impersonatedSub, 
    scope: scope,
    aud: "https://oauth2.googleapis.com/token",
    exp: iat + 3600, iat: iat
  };
  
  const claim = btoa(JSON.stringify(claimPayload));
  
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    parsePem(credentials.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false, ["sign"]
  );
  
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", cryptoKey, new TextEncoder().encode(`${header}.${claim}`));
  const jwt = `${header}.${claim}.${btoa(String.fromCharCode(...new Uint8Array(signature))).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_')}`;
  
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${jwt}`
  });
  const data = await res.json();
  return data.access_token;
}

function parsePem(pem) {
  const b64 = pem.replace(/-----\w+ PRIVATE KEY-----/g, "").replace(/\n/g, "");
  const binStr = atob(b64);
  const bytes = new Uint8Array(binStr.length);
  for (let i = 0; i < binStr.length; i++) bytes[i] = binStr.charCodeAt(i);
  return bytes.buffer;
}
