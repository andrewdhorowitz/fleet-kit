# Middleware groups update — 2026-11-12

Prepared by Muse, Nov 12, 2026, at Andrew's direction ("lets get
middleware updated too", in the app-release group work). Build report:
`~/workspace/goals/shared-service-layer-cloudflare-firebase-google-cloud/files/middleware-groups-update-2026-11-12.md`.

**Status: PREPARED, NOT RUN.** Nothing here has executed and the live
Worker is unchanged. Middleware maintenance is owner-run by standing
rule: Andrew runs the update script once in Termux.

## What changes when this runs

1. **The Worker becomes registry-aware.** `middleware/src/index.js`
   (committed beside this package) resolves every `groups.*` call
   against a server-side registry of the four app-release groups
   instead of passing a free-form `groupKey` straight to Google:
   - `groupKey` may be a registry key (`owners`, `early-testers`,
     `family`, `trusted-contacts`), the consumer address, or the
     domain address — it always resolves to the group's **domain**
     address (`apps-release-*@andrewdhorowitz.com`) for the API call.
   - Consumer `@googlegroups.com` addresses are recorded as the
     current/manual state only. Admin SDK + domain-wide delegation
     cannot manage consumer groups (Nov 11, 2026 live test), so the
     Worker never calls them directly.
   - **Family** has no domain group in the Workspace plan
     (`tester-groups.json`, Nov 12 note), so calls against it return
     `needs_owner` with state `manual_only` — membership there stays
     a manual Groups-UI step.
   - Unknown groups are refused with a validation error.
2. **Owners is manual-only — DECIDED Nov 12, 2026.** Andrew chose
   option (b) on the approval-redemption question, in his words:
   "Manual change and listen for change artifacts and activate any
   next actions." Any `groups.members.add` /
   `groups.members.remove` against the Owners group returns
   `needs_owner` with state `manual_only`: Owners membership
   changes are made by Andrew by hand in the Google Groups UI, and
   the middleware **never** executes them. The approval-redemption
   protocol addition is **not** being built. (This supersedes the
   earlier OWNERS GATE `needs_approval` preview encoding of runbook
   rule (d); the §3.7 preview machinery itself is untouched and
   still serves the other consequential actions.) Ordinary groups
   are unchanged at the Worker layer: their one-click confirmation
   is enforced at the caller layer by Andrew's standing click rule
   and recorded per group in the registry.
   **The witness leg:** `groups.get` on Owners stays enabled — for
   this group the middleware is read-only witness. When a roster
   change is observed, Muse surfaces it and activates the standing
   next actions (verify Play tester-list implications; records
   sweep of TESTER-LINKS.md / unified-group-config.json /
   tester-groups.json). The witness activates only once the
   Workspace chain below has landed and the settling `groups.get`
   test passes; until then, manual Owners changes are not
   observable to the middleware.
3. **The registry is deposited as a Worker secret**
   (`MW_GROUP_REGISTRY`) — configuration riding the fleet's
   established owner-run secret channel, so addresses can be
   corrected later by editing one JSON file and re-running, with no
   code change. Nothing else about the Worker changes: the action
   catalog, the DWD scope, the ledger/audit behavior, and the known
   HTTP-500 error-builder defect are all untouched.

## Your steps (YOU)

Run this **after** the Workspace dependency chain is in place
(domain groups created → DWD sitting done → admin email ready to
switch). The script is safe to run earlier, but the settling test
only passes once the chain exists.

**YOU-1 — Cloudflare API token (once per run).** Needs Workers
Scripts Edit on the account (the same class as the Nov 10 setup).
Either export it in the Termux session:

```
export CLOUDFLARE_API_TOKEN=<token>
```

or save it as one line in `~/cloudflare-api-token.txt`
(`chmod 600`). Revoke it after the run.

**YOU-2 — (Optional) the admin-email switch.** To fold the
`WORKSPACE_ADMIN_EMAIL` switch to the Workspace admin into the same
run, export the new value in the session (entered on-device only;
it never enters this repo):

```
export MW_WORKSPACE_ADMIN_EMAIL=andrew@andrewdhorowitz.com
```

**YOU-3 — (Optional) override the domain addresses.** If any domain
group address differs from `group-registry.json` in this package,
put the corrected registry JSON at `~/mw-group-registry.json` — the
script prefers it over the packaged file.

**YOU-4 — Run it.** From the fleet-kit checkout on the phone:

```
node middleware/groups-update-2026-11-12/update-middleware-groups.mjs
```

It is non-interactive and idempotent: a re-run re-verifies and only
re-applies what is missing. It creates nothing on any provider
control plane — it updates the one existing Worker and its secrets.

## Then (ME)

Muse runs the settling test from the connector side:

```
mw.py capabilities
mw.py invoke groups.get execute '{"groupKey":"trusted-contacts"}' "Groups update settling test"
```

A roster coming back proves the whole leg end to end: domain groups
exist, the DWD grant works, the registry resolves, and the Worker can
manage Workspace groups. `groups.get` against `owners` is the second
read — and it doubles as the witness baseline: the Owners roster
observed there is the reference the roster-diff watch compares
against (Andrew's Nov 12, 2026 decision (b)). An Owners **add**
through the middleware deliberately returns `manual_only` — Owners
changes are made by hand in the Groups UI.

## Rollback

The previous Worker source is the prior commit of
`middleware/src/index.js` in this repo's history. Restore it and
re-run `setup-middleware.mjs`'s deploy (or this script after checking
out that source) to revert the code; the old code ignores
`MW_GROUP_REGISTRY`, which can then be deleted in the Cloudflare
dashboard. No data is migrated by this update, so nothing else needs
unwinding.
