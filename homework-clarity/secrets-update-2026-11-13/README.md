# Homework Clarity secrets update — 2026-11-13 (owner-run)

**What this does:** deposits the three secrets the `homework-clarity`
Worker needs and currently does not have (its secret list is empty):
`GOOGLE_CLIENT_ID` + `GOOGLE_CLIENT_SECRET` (so the in-app
**Connect calendar** consent flow can run — per-kid blocker
calendars) and `GEMINI_API_KEY` (so photo-scan extraction is the
real AI instead of the labeled sample fallback). Values travel from
your consoles to your Termux session to the Worker secret store —
never through chat, never to Muse. The script verifies by reading
back secret **names only**.

**Partial runs are fine:** the three exports are independently
optional. Export whichever values you have in hand — the script
deposits those, names the ones it skipped, and a later re-run with
the remaining exports set completes the set. It aborts only if
none of the three is exported.

**Who runs what:** YOU steps are Andrew's (consoles + one Termux
run). ME steps are Muse's, after the run.

---

## YOU-1 — Have the values ready (any subset is fine)

All three live in the Google Cloud project
**gen-lang-client-0590645241**:

1. **GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET** —
   console.cloud.google.com → **APIs & Services → Credentials** →
   the **OAuth web client** Firebase auto-created in that project.
   Open it; the client ID and client secret are on that page. Keep
   the tab open for YOU-2.
2. **GEMINI_API_KEY** — the API key for the same project (AI Studio
   / Google Cloud Console → APIs & Services → Credentials → API
   keys).

## YOU-2 — Run the deposit in Termux

The script reads the Cloudflare token from
`~/cloudflare-api-token.txt` (the token already there works if you
haven't revoked it; if you have, make a fresh one with **Workers
Scripts Edit** on the account and save it there — one line, the
raw token only). Or export `CLOUDFLARE_API_TOKEN` in the session
instead.

```
cd ~/work/fleet-kit && git pull
export HC_GOOGLE_CLIENT_ID=<client ID from YOU-1>
export HC_GOOGLE_CLIENT_SECRET=<client secret from YOU-1>
export HC_GEMINI_API_KEY=<API key from YOU-1>
node homework-clarity/secrets-update-2026-11-13/update-homework-clarity-secrets.mjs
```

Export only what you have — any one, two, or all three lines.
Example, client ID only:

```
cd ~/work/fleet-kit && git pull
export HC_GOOGLE_CLIENT_ID=<client ID from YOU-1>
node homework-clarity/secrets-update-2026-11-13/update-homework-clarity-secrets.mjs
```

A full run ends with `=== SECRETS SET AND VERIFIED ===`; a
partial run ends with `=== PARTIAL RUN COMPLETE ===` and names
what's still missing. A failure prints exactly which leg failed
and is safe to re-run. If none of the three exports is set, the
script stops before any API call and says so.

## YOU-3 — Two console follow-ups (the script also prints these)

1. **Redirect URI:** on that same OAuth client (YOU-1), add
   **Authorized redirect URI** exactly:
   `https://homework.andrewdhorowitz.com/calendar/auth/callback`
   → Save. Without it Google refuses the consent at the last step.
2. **Firestore rules:** Firebase console → project
   **gen-lang-client-0590645241** → **Firestore Database → Rules**
   → replace the editor contents with the current rules file from
   the homework-clarity project (`firestore/firestore.rules` — ask
   Muse to show you the text) → **Publish**. The per-kid pickers
   can't save until this lands.

## ME — Muse's steps after your run

- Re-list the Worker's secret names from the deploy tooling and
  confirm the ones set in your run are present (names only), and
  note which of the three remain for a later run.
- Walk the consent sitting with you: app → sign in as fourpshot →
  Parent view → **Connect calendar** → approve the calendar.readonly
  consent → pickers: **Alexis → her calendar, Bailey → hers** — then
  verify each kid's blocks come only from her own picked calendar.

**Token hygiene:** the Cloudflare token in
`~/cloudflare-api-token.txt` can be revoked after this run.
