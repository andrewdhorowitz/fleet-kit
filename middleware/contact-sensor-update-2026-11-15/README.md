# Middleware contact-sensor update — 2026-11-15 (owner-run)

One change: the named-automation virtual device in the
`andrew-middleware` Worker is now presented to Google Home as a
**contact sensor** instead of a switch (Andrew's direction,
Nov 15, 2026).

Why: the switch presentation (`action.devices.types.SWITCH` +
`OnOff`) is never offered as a starter in Google Home's
automation editor, so no routine could fire from a pulse — on
Nov 14 the pulses were accepted by Home Graph all evening and
triggered nothing. Door/contact devices ARE offered as starters
("when the contact opens"). In cloud-to-cloud terms a contact
sensor is:

- type `action.devices.types.DOOR`
- trait `action.devices.traits.OpenClose`
- attributes `{ discreteOnlyOpenClose: true, queryOnlyOpenClose: true }`
  (Google's trait reference: "Sensors that can only report open
  state should set queryOnlyOpenClose to true")

Same registry entry, same device id
(`mw-automation-claude-wake-up-tv`), same display name — only
the presentation changes. The pulse now reports `openPercent`
100 (open), holds (the 10-second hold from
`pulse-hold-update-2026-11-14` rides along in the same source —
if that package was never run, this deploy brings both), then
reports 0 (closed).

## Run it (Termux, as owner)

```
cd ~/work/fleet-kit && git pull
node middleware/contact-sensor-update-2026-11-15/update-middleware-contact-sensor.mjs
```

The script reads the Cloudflare token from
`~/cloudflare-api-token.txt` (or `CLOUDFLARE_API_TOKEN`) — the
same token file the sign-in and pulse-hold updates used. No
exports needed.

## What it does

1. Verifies the token, finds the account and the existing D1
   binding.
2. Uploads `middleware/src/index.js`, re-applying BOTH bindings
   (a script upload replaces the binding list): the `DB` D1
   binding and the `HOME_ALLOWED_EMAIL` plain-text variable the
   sign-in gate needs. Skips the deploy if the live script
   already carries this package's marker.
3. Verifies by read-back: the marker and the DOOR + OpenClose
   presentation on the live script, both bindings present, the
   expected secret names present (names only, never values),
   and `/v1/health` ok.

Success ends with `=== UPDATE APPLIED AND VERIFIED ===`.

## After it runs (owner steps)

1. **Unlink + relink** `[test] Andrew Google Bridge` in Google
   Home (account chooser; pick fourpshot). A device type change
   only lands on a fresh SYNC, and the automatic requestSync is
   still broken — the relink is what delivers the new
   presentation.
2. MuseWakeUpTv comes back as a contact sensor (a door). Build
   the routine with the starter **"MuseWakeUpTv opens"** and
   the action "Bedroom TV on".
3. Tell Muse — the next pulse opens the contact for 10
   seconds, then closes it.
