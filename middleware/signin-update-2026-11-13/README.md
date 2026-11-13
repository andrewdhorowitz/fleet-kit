# Middleware sign-in gate update — 2026-11-13 (owner-run)

**What this does:** account linking for **Andrew Google Bridge** stops
asking for a typed link code and instead requires **Google sign-in**:
only **fourpshot@gmail.com** gets through; any other signed-in account
gets a dead-end page ("You can't use this. Bye."). The link code stays
as a fallback until Andrew retires it. Design: spec §11 in
`named-automations-spec-2026-11-13.md` (goal workspace). The same
deploy also makes Home Graph failures report Google's own error text
(the requestSync 400 diagnosis).

**Who runs what:** YOU steps are Andrew's (console + one Termux run).
ME steps are Muse's, after the run.

---

## YOU-1 — Create the web OAuth client (one time, ~5 minutes)

In the Cloud console, signed in as **andrewhorowitz3**, with the
project picker set to **andrew-mw-workspace**:

1. **APIs & Services → OAuth consent screen**
   - User type: **External** → Create.
   - App name: `Andrew Google Bridge`; user support email and
     developer contact: `fourpshot@gmail.com`. Save and continue
     through Scopes (nothing to add) to **Test users**.
   - **Add users → fourpshot@gmail.com** → Save.
   - Leave the app in **Testing** status — do not publish. You are
     the only test user, which is exactly the point.
2. **APIs & Services → Credentials → Create credentials → OAuth
   client ID**
   - Application type: **Web application**.
   - Name: `Andrew Google Bridge linking`.
   - **Authorized redirect URIs → Add URI**, exactly:
     `https://andrew-middleware.andrewhorowitz3.workers.dev/home/auth/callback`
   - Create. The dialog shows the **client ID** and **client
     secret** — keep that tab open for YOU-2. These two values
     never go through chat and never to Muse; they travel from
     the console to your Termux session to the Worker secret store.

## YOU-2 — Run the update in Termux

The script reads the Cloudflare token from
`~/cloudflare-api-token.txt` (this morning's token works if you
haven't revoked it yet; if you have, make a fresh one with
**Workers Scripts Edit** and save it there — one line, the raw
token only).

```
cd ~/work/fleet-kit && git pull
export MW_SIGNIN_CLIENT_ID=<client ID from YOU-1>
export MW_SIGNIN_CLIENT_SECRET=<client secret from YOU-1>
node middleware/signin-update-2026-11-13/update-middleware-signin.mjs
```

Success ends with `=== UPDATE APPLIED AND VERIFIED ===`, including a
live probe that /home/auth now redirects to Google sign-in. A failure
prints exactly which leg failed and is safe to re-run.

## YOU-3 — Prove it in Google Home

1. Unlink **[test] Andrew Google Bridge**, then link it again.
   There should be **no code page** — just the Google account
   chooser. Pick **fourpshot**; it links.
2. Look for the **MuseWakeUpTv** switch in the home (the fresh
   link re-syncs the registry). Tell Muse whether it appeared.

## YOU-4 — Optional, decisive: the wrong-account test

Unlink once more, link again, and this time choose
**andrewhorowitz3**. You should land on a plain page that says only
"You can't use this. Bye." — nothing links. Then link again as
fourpshot to leave it in the good state.

## ME — Muse's settling tests after your run

- `mw.py capabilities` + `home.automations.list` (service healthy).
- Retry the registry sync; with the diagnostic improvement live,
  the result now carries Google's own error wording if it still
  fails, which settles the wrong-key vs registration question.
- Build report filed in the goal workspace; spec §11 updated with
  the outcome.

**Token hygiene:** the Cloudflare token in
`~/cloudflare-api-token.txt` can be revoked after this run, same as
this morning's.
