# Middleware text channel update — 2026-11-16 (owner-run)

One change: the `andrew-middleware` Worker gains a general
text in / text out action, **`text.process`** (Andrew's
direction, Nov 16, 2026: "whatever text you want in and
whatever text you want out").

Why this shape: nothing inside the middleware is irreversible
— no one is using it — and the front door is not changing
dramatically. So instead of a new endpoint per case, one
general action rides the existing gated invoke surface: same
bearer auth, same envelope, same D1 ledger and audit rows as
every invoke.

What it does:

- Params: `text` (string, required, max 16,384 chars) and
  `transform` (optional, default `identity`).
- Transforms are a fixed allowlist of pure functions in code:
  `identity`, `uppercase`, `lowercase`, `reverse`,
  `word_count`, `sha256`. Nothing caller-supplied ever runs.
- Result: `{ text_out, transform, input_chars, output_chars }`
  in the standard invoke response; the envelope's ledger row
  stores the response like every other invoke.
- Class: `read` — the handler mutates nothing, calls no
  provider, and writes no rows of its own. Constructive only:
  no deletes, no external sends, no state destruction.

The named-automation registry (`home.automations.*`) and all
existing actions are unchanged.

## Run it (Termux, as owner)

```
cd ~/work/fleet-kit && git pull
node middleware/text-channel-update-2026-11-16/update-middleware-text-channel.mjs
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
   live script already carries this package's marker.
3. Verifies by read-back: the marker and the `text.process`
   action on the live script, both bindings present, the
   expected secret names present (names only, never values),
   and `/v1/health` ok.

Success ends with `=== UPDATE APPLIED AND VERIFIED ===`.

## After it runs (owner steps)

1. Tell Muse — verification from Muse's side is:
   capabilities lists `text.process`, then one real invoke
   round-trip (text in → text out).
2. No Google Home relink is needed; this update changes no
   device presentation, only the invoke catalog.
