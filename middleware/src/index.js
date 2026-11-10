// file: src/index.js
// path: ./src/index.js

const ACTION_CATALOG = {
  // --- WAVE 1A ACTIONS ---
  "groups.members.add": { class: "mutation", async: false },
  "groups.members.remove": { class: "mutation", async: false }, // F1: implemented below
  "groups.get": { class: "read", async: false },
  "play.apps.create": { class: "consequential", async: true },
  "jobs.get": { class: "read", async: false }, // F1: implemented below
  
  // --- UNRATIFIED JUDGMENT CALLS (§1.8) EXPLICITLY ENCODED HERE ---
  "releases.internal.publish": { class: "consequential", async: true }, // (1) Internal-track releases block
  "iam.policy.set": { class: "consequential", async: false },           // (2) IAM policy caution
  "gcp.projects.create": { class: "consequential", async: true },       // (3) Project creation stops
  "contacts.merge": { class: "mutation", async: false },                // (4) Contact-merge confidence bar
  "calendar.events.delete": { class: "mutation", async: false }         // (5) Shared-calendar deletes
};

export default {
  async fetch(request, env, ctx) {
    const startTime = Date.now();
    let auditId = `mw-${new Date().toISOString().replace(/[-:T.]/g, "").slice(0,14)}-${Math.random().toString(36).substring(2,6)}`;
    
    // 1. Health & Capabilities Check
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/v1/health") return new Response(JSON.stringify({ status: "ok" }), { status: 200 });
    
    // 2. Authentication (§3.2)
    const authHeader = request.headers.get("Authorization");
    if (!authHeader || authHeader !== `Bearer ${env.MUSE_BEARER_TOKEN}`) {
      return errorResponse("unauthorized", false, "Invalid or missing token", "middleware", startTime, auditId, 401);
    }

    if (request.method === "GET" && url.pathname === "/v1/capabilities") {
      return new Response(JSON.stringify({
        service: "middleware", protocol_version: 1,
        actions: Object.entries(ACTION_CATALOG).map(([act, meta]) => ({ action: act, ...meta })),
        passthrough_allowlist: [] 
      }), { status: 200 });
    }

    if (request.method !== "POST" || url.pathname !== "/v1/invoke") {
      return errorResponse("validation", false, "Invalid endpoint", "middleware", startTime, auditId, 404);
    }

    // 3. Parse Envelope (§3.3)
    let body;
    try { body = await request.json(); } catch (e) {
      return errorResponse("validation", false, "Malformed JSON", "middleware", startTime, auditId, 400);
    }

    const { request_id, action, mode, params, context, approval } = body;
    if (!request_id || !action || !mode || !context?.reason) {
      return errorResponse("validation", false, "Missing required envelope fields", "middleware", startTime, auditId, 400);
    }
    
    if (!ACTION_CATALOG[action]) {
      return errorResponse("unknown_action", false, `Action ${action} not in catalog`, "middleware", startTime, auditId, 400);
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
      finalResponse = await routeAction(action, mode, params, context, approval, env, request_id, auditId, startTime);
    } catch (err) {
      finalResponse = errorResponse("internal", true, err.message, "middleware", startTime, auditId, 500, request_id);
    }

    // 6. Finalize Ledger & Audit
    await env.DB.prepare("UPDATE ledger SET status = ?, response_json = ? WHERE request_id = ?")
      .bind(finalResponse.status, JSON.stringify(finalResponse), request_id).run();
      
    await env.DB.prepare("INSERT INTO audit (audit_id, request_id, caller, action, reason) VALUES (?, ?, ?, ?, ?)")
      .bind(auditId, request_id, "muse", action, context.reason).run();

    return new Response(JSON.stringify(finalResponse), { status: 200, headers: { "Content-Type": "application/json" } });
  }
};

async function routeAction(action, mode, params, context, approval, env, request_id, auditId, startTime) {
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
    
    // F2: DWD Implementation with `sub` claim impersonating the workspace admin and strict scoping
    const scope = "https://www.googleapis.com/auth/admin.directory.group.member";
    const token = await getGoogleAccessToken(env.GCP_WORKSPACE_SA_KEY, scope, env.WORKSPACE_ADMIN_EMAIL);
    if (!token) throw new Error("Failed to generate Google Workspace DWD token");

    if (action === "groups.get") {
      const res = await fetch(`https://admin.googleapis.com/admin/directory/v1/groups/${params.groupKey}/members`, {
        headers: { Authorization: `Bearer ${token}` }
      });
      if (!res.ok) throw new Error(`Google API returned ${res.status}`);
      const data = await res.json();
      return buildResponse(request_id, auditId, "completed", action, {}, data, startTime);
    }
    
    if (action === "groups.members.add") {
      if (!params.email) throw new Error("validation: Email required");
      const res = await fetch(`https://admin.googleapis.com/admin/directory/v1/groups/${params.groupKey}/members`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ email: params.email, role: "MEMBER" })
      });
      if (!res.ok) throw new Error(`Google API returned ${res.status}`);
      
      const evidenceRes = await fetch(`https://admin.googleapis.com/admin/directory/v1/groups/${params.groupKey}/members`, {
        headers: { Authorization: `Bearer ${token}` }
      });
      const evidence = await evidenceRes.json();
      return buildResponse(request_id, auditId, "completed", action, { added: params.email }, evidence, startTime);
    }

    // F1: groups.members.remove Implementation (Silent correction shape + read-back evidence)
    if (action === "groups.members.remove") {
      if (!params.email) throw new Error("validation: Email required");
      const res = await fetch(`https://admin.googleapis.com/admin/directory/v1/groups/${params.groupKey}/members/${params.email}`, {
        method: "DELETE",
        headers: { Authorization: `Bearer ${token}` }
      });
      // Treat 404 (already gone) as success for silent correction
      if (!res.ok && res.status !== 404) throw new Error(`Google API returned ${res.status}`);
      
      const evidenceRes = await fetch(`https://admin.googleapis.com/admin/directory/v1/groups/${params.groupKey}/members`, {
        headers: { Authorization: `Bearer ${token}` }
      });
      const evidence = await evidenceRes.json();
      return buildResponse(request_id, auditId, "completed", action, { removed: params.email }, evidence, startTime);
    }
  }

  throw new Error(`Action ${action} implemented but handler missing.`);
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
