# Middleware pulse-hold update — 2026-11-14 (owner-run)

One change: the named-automation pulse in the `andrew-middleware`
Worker now holds its virtual switch ON for **10 seconds** instead
of 1 before resetting off (Andrew's direction, Nov 14, 2026 — the
1-second flash was too fast to see on the Google Home tile while
testing the TV wake path). The TV still turns on at the rising
edge; the longer hold only keeps the tile lit longer. One constant
in `middleware/src/index.js`: `HOME_PULSE_HOLD_MS 1000 -> 10000`.

## Run it (Termux, as owner)

```
cd ~/work/fleet-kit && git pull
node middleware/pulse-hold-update-2026-11-14/update-middleware-pulse-hold.mjs
```

The script reads the Cloudflare token from
`~/cloudflare-api-token.txt` (or `CLOUDFLARE_API_TOKEN`) — the
same token file tonight's sign-in update used. No exports needed.

## What it does

1. Verifies the token, finds the account and the existing D1
   binding.
2. Uploads `middleware/src/index.js`, re-applying BOTH bindings
   (a script upload replaces the binding list): the `DB` D1
   binding and the `HOME_ALLOWED_EMAIL` plain-text variable the
   sign-in gate needs. Skips the deploy if the live script
   already carries this package's marker.
3. Verifies by read-back: the marker and the 10 s constant on the
   live script, both bindings present, the expected secret names
   present (names only, never values), and `/v1/health` ok.

Success ends with `=== UPDATE APPLIED AND VERIFIED ===`. No
Google Home steps follow — tell Muse, and the next pulse uses
the 10-second hold.
