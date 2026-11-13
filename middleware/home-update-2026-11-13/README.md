# Middleware home update — 2026-11-13 (named automations)

Prepared by Muse, Nov 13, 2026, at Andrew's direction — the named-automations spec (`named-automations-spec-2026-11-13.md`) was **approved Nov 13, 2026, 00:52 EST**, and his approval couples to starting the build. Build report: `~/workspace/goals/shared-service-layer-cloudflare-firebase-google-cloud/files/named-automations-build-report-2026-11-13.md`.

**Status: PREPARED, NOT RUN.** Nothing here has executed and the live Worker is unchanged. Middleware maintenance is owner-run by standing rule: Andrew runs the update script once in Termux.

## What changes when this runs

Two change sets ride in the one source (`middleware/src/index.js`), kept separate in the code and the build report:

1. **Named automations (change set 1).** The middleware itself becomes the linked Smart Home service:
   - New routes `/home/auth` (link-code-gated account-linking page), `/home/token` (OAuth grants; tokens stored hash-only in D1), `/home/fulfill` (SYNC / QUERY / EXECUTE / DISCONNECT). SYNC renders **dynamically from the registry** — one virtual switch per named automation.
   - New D1 tables in the existing `middleware-ledger` database: `home_automations` (the registry: slug → device_id, display_name, active, cooldown_seconds default 10, known_state, last_pulse_at), `home_links`, `home_tokens`, `home_pulses`.
   - New catalog actions: `home.automations.list` (read), `home.automations.upsert`, `home.automations.set_enabled`, `home.automations.remove` (mutations), and `home.automations.pulse` (mutation). Registry mutations fire an automatic Home Graph `requestSync`.
   - The pulse implements spec §4 exactly — registry-only + enabled-only refusals, per-automation cooldown, one idempotency key per pulse (a repeat key returns the original record, no second pulse), pre-flight off when the known state is ON/unknown, 1,000 ms hold, reset-off retried twice in `waitUntil`, exhausted resets flagged `STUCK_ON_RESET_FAILED` — and the §5 honesty contract: HTTP 200 carries `pipeline_stage: "TRIGGER_DISPATCHED"` with `automation_fired` / `target_device_acted` both `"UNOBSERVABLE"`; HTTP 502/504 only when Home Graph itself rejects the reportState call. New registry entries start **inactive** — being listed never makes an automation triggerable; Andrew explicitly enables each one.
   - New Worker secrets (names only here): `HOME_LINK_CODE` (the linking gate; Andrew invents the value) and `GOOGLE_HOME_SA_JSON` (the Home Graph service-account key — the same JSON already deposited on the text-bridge Worker, but a **separate deposit on this Worker**; the script checks presence only and never handles the value).
2. **Error-response fix (change set 2, Middleware Exchange 3).** The pre-envelope error paths returned a bare object instead of an HTTP Response, so unauthenticated/malformed calls surfaced as HTTP 500. They now return proper Responses: **401 before any action parsing**, 400 for malformed/invalid envelopes, 404 for unknown endpoints. No action behavior changes; the in-envelope protocol shape for action errors is untouched.

Everything else is preserved: all ten existing actions, the §3.7 consequential preview machinery, the ledger/audit behavior, and the Nov 12 groups work — including Owners as manual-only (decision (b)); the dry checks re-verified an Owners add still returns `needs_owner` / `manual_only`.

## Your steps (YOU)

**YOU-1 — Cloudflare API token (once per run).** Needs Workers Scripts Edit + D1 read on the account. Either export it in the Termux session:

```
export CLOUDFLARE_API_TOKEN=<value from your password manager>
```

or save it as one line in `~/cloudflare-api-token.txt` (`chmod 600`). Revoke it after the run.

**YOU-2 — (Optional, recommended) the link code.** Invent the link code for the new service and export it so the same run deposits it:

```
export MW_HOME_LINK_CODE=<a passphrase you invent>
```

It is entered on-device only, never printed by the script, and never carried in this repo. (Or add the `HOME_LINK_CODE` secret in the Cloudflare dashboard instead.)

**YOU-3 — Run it.** From the fleet-kit checkout on the phone:

```
node middleware/home-update-2026-11-13/update-middleware-home.mjs
```

Non-interactive and idempotent. It deploys the source, applies the home schema, and verifies by read-back. **Fail-safe:** if `GOOGLE_HOME_SA_JSON` is not yet a secret on the `andrew-middleware` Worker, the script stops with an INCOMPLETE report and prints the deposit step — the deposit is yours alone (Cloudflare dashboard, value read on your own device; it never passes through chat or Muse). Re-running after the deposit finishes the verification.

**YOU-4 — Actions console + linking** (after the script verifies): create the Smart Home action in the `family-routines-app` Google Cloud project under **your chosen service name** (spec §9b — the exact name is yours to settle; the code uses a placeholder), with fulfillment URL `https://andrew-middleware.andrewhorowitz3.workers.dev/home/fulfill`, account-linking URLs `…/home/auth` and `…/home/token` (OAuth / Authorization Code; console client ID/secret may be any values — the Worker ignores them, the link code is the gate), release to Test, then link it in Google Home with the link code.

**YOU-5 — First automation name.** Create the first automation in Google Home (your rebuilt home) and tell Muse its name — that seeds the first registry entry (starts inactive; enabling is the separate explicit step).

## Then (ME)

Muse's settling tests from the connector side: `mw.py capabilities` (the five `home.automations.*` actions listed), `home.automations.list` (empty registry), seed + enable the first entry once YOU-5 lands, and the watched pulse test at the TV (spec §8/§10) before the Family Board link is unlinked as cleanup.

## Rollback

The previous Worker source is the prior state of `middleware/src/index.js` in this repo's history. Restore it and re-deploy (setup script's deploy step or the groups update script after checking out that source) to revert the code; the home tables are additive and ignored by the old code, and `HOME_LINK_CODE` / `GOOGLE_HOME_SA_JSON` can be deleted in the dashboard. No existing data is migrated or altered by this update.
