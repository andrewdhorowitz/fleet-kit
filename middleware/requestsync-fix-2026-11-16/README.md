# Middleware requestSync fix — 2026-11-16 (owner-run)

One change: the Home Graph **`devices:requestSync`** call in the
`andrew-middleware` Worker no longer sends a `requestId` field in
its payload. Google rejects that field on requestSync
(`homegraph_http_400`); the payload is now `agentUserId` +
`async` only. Nothing else about the call changes. (The
`reportStateAndNotification` call keeps its `requestId` — that
API accepts it.)

This deploy also lands the still-pending **text channel**
update (`text.process`): both changes live in the same
`middleware/src/index.js`, and every update package deploys that
one source. Running this package once covers both — the
text-channel package does **not** need its own run afterwards
(its marker will already be live; if run anyway it skips its
deploy and passes its read-backs).

## Run it (Termux, as owner)

```
cd ~/work/fleet-kit && git pull && node middleware/requestsync-fix-2026-11-16/update-middleware-requestsync-fix.mjs
```

The script reads the Cloudflare token from
`~/cloudflare-api-token.txt` (or `CLOUDFLARE_API_TOKEN`) —
the same token file the earlier updates used. No exports
needed.

## What it does

1. Verifies the token, finds the account and the existing D1
   binding.
2. Uploads `middleware/src/index.js`, re-applying BOTH
   bindings (a script upload replaces the binding list): the
   `DB` D1 binding and the `HOME_ALLOWED_EMAIL` plain-text
   variable the sign-in gate needs. Skips the deploy if the
   live script already carries this package's marker. Before
   deploying it refuses a stale checkout: the local source
   must carry the fix marker, the fixed payload, the
   text-channel marker — and must NOT carry the rejected
   `requestId` payload form.
3. Verifies by read-back: the fix marker + fixed payload (and
   the absence of the rejected form) on the live script, the
   text-channel marker and `text.process` action riding along,
   both bindings present, the expected secret names present
   (names only, never values), and `/v1/health` ok.

Success ends with `=== UPDATE APPLIED AND VERIFIED ===`.

## After it runs (owner steps)

1. Tell Muse — verification from Muse's side is:
   `/v1/health` ok, capabilities lists `text.process` (proof
   the combined source deployed), then one home action that
   triggers a registry requestSync — its result must show
   `request_sync: "requested"` with no `homegraph_http_400`.
2. No Google Home relink is needed; this update changes no
   device presentation.
