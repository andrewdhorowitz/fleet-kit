# error-reporter — visitor error reporting, core module

A dependency-free error-reporting core for static sites and small web apps: one
funnel function that every failure passes through, a shared tier-classification
table, and pluggable backend sinks chosen by a single config value. It records
*codes and context only — never user data*.

This is the published snapshot. The module is developed and tested in a private
kit repository (plain-Node test suite, **35 passed, 0 failed**, including a
poisoned-sink suite) and published here for the public projects to consume.

## Files

| File | What it is |
|---|---|
| `error-reporter.js` | The funnel core: `reportError`, classification, sinks, global handlers, boot flag/timer. Dependency-free, framework-free, runs as a classic script or a Node module. |
| `error-tiers.js` | The shared classification table (drop-class + expected tiers, every entry commented). One copy for the whole fleet. |

## The contract (non-negotiable parts)

- **One funnel.** Host code calls `reportError(err, ctx)` and never talks to a backend.
- **Fixed event shape.** Emitted events have exactly these fields, nothing else:
  `{ code, tier, area, operation, recovered, release, page, site, ts }`. No user data,
  nothing a visitor typed — codes and context only.
- **Tier 3 is never assigned in the page.** It is earned only at the log, from
  aggregate signals (same code across many browsers, a spike, a first sighting
  right after a release).
- **The reporter can never throw into the host page.** Every path — funnel, classifier,
  sink dispatch, global handlers — is wrapped, and async sink rejections are swallowed.
  A dead backend must be indistinguishable from a healthy one.
- **Per-code throttle.** Within one page session, only the first `throttlePerCode`
  occurrences of each error code reach the sink (default 10). The rest are counted,
  not sent — see section 3b.

## Adopting it

### 1. Include and configure

```html
<script src="error-tiers.js"></script>
<script src="error-reporter.js"></script>
<script>
  ErrorReporter.configure({
    site: 'example-site',          // fleet-unique site tag
    release: '7509751',            // deploy commit SHA (see "Release stamp" below)
    sink: 'worker',                // 'firestore' | 'worker' | 'sentry' | 'none' | 'memory' | function
    workerUrl: 'https://errors.example.com/collect'
  });
  ErrorReporter.installGlobalHandlers();
  ErrorReporter.armBootTimer(10000); // optional; markBooted() disarms it
</script>
```

For per-instance use (and in tests), `ErrorReporter.createReporter(config)` returns an
independent reporter with the same methods.

### 2. Config reference

| Key | Meaning |
|---|---|
| `site` | Site tag carried on every event (`example-app`, `example-site`, …). |
| `release` | Release stamp carried on every event. Should be the deploy's commit SHA. |
| `sink` | Backend adapter, chosen by this one value. A function may be passed directly (custom sink / tests). |
| `workerUrl` | Collector URL for the `worker` sink (sendBeacon, fetch-keepalive fallback). |
| `firestoreWriter` | Injected writer for the `firestore` sink — see below. The module imports nothing. |
| `sentry` | An injected `@sentry/browser` module object (bundled adopters). If absent, the CDN bundle's global `Sentry` is used. |
| `tiers` | Tier-table overrides, merged over `error-tiers.js`. |
| `throttlePerCode` | Per-code, per-session sink cap (default `10`). `Infinity` disables the throttle. See section 3b. |

### 3. Report failures, with context

```js
try {
  await tasksCol.doc(id).update({ done: true });
} catch (e) {
  reporter.reportError(e, { area: 'tasks', operation: 'toggle-task', writeAmbiguous: true });
}
```

`ctx` signals the classifier uses (all optional): `area`, `operation`, `deliberate`
(drop), `recovered` (`true` / `false` / `'pending'`), `writeAmbiguous` (floors the
tier at 1, overriding recovery), `sessionDead`, `canContinue`, `beforeBoot`, `page`.
Known codes take their expected tier from `error-tiers.js`; effect signals override
the table; unknown codes classify purely by effect (default Tier 1, Tier 2 when the
session is dead or the boot flag had not set).

**Payload decision (Oct 29, 2026):** the event shape was amended from 8 fields to 9
before the first real adoption, while amending was free: `operation` is carried on
every event, taken from `ctx.operation` (`null` when the call site doesn't name one),
because grouping and correlation lean on it heavily. The resource URL remains
`ctx`-only — used for classification, not stored.

### 3b. Per-code throttle

The funnel throttles per error code, per page session. The first `throttlePerCode`
occurrences of a code (default **10**, set in config; `Infinity` disables) are
reported normally; every further occurrence of that code returns `null` like a drop
but is **counted, not sent**. Each code has its own independent budget, a new
reporter instance (a new page session) starts fresh, and drop-class errors return
before the throttle, so deliberate cancels never consume the cap.

Why it exists: quota insurance. The realistic way to burn Sentry's 5,000
events/month or a day of Workers requests is one visitor's page looping on the
same error — the throttle caps that at 10 events per code per session while losing
nothing diagnostically important (the first 10 carry the code, operation, and
context; occurrences 11+ are the same failure repeating).

**Suppressed counts — the deliberate design choice:** they live in reporter state
only, readable in-page via `reporter.getThrottleStats()` (a
`{ code: { reported, suppressed } }` map, for tests and debugging). No summary
event is emitted on page unload: a flush would itself spend the quota the throttle
protects, and unload-time delivery races page teardown. The accepted trade-off is
that suppressed counts don't reach the log; the log instead shows each code
plateauing at the cap, which is itself the signal that a loop occurred.

### 4. Mark boot

Call `markBooted()` when the app/page first becomes usable (in an app: after init +
first successful data subscribe). Errors the global handlers catch before that point
classify as session-dead. `armBootTimer(ms)` turns a never-booted page into a
`boot-timeout` report (Tier 2).

**CDN-death caveat:** if a page's framework CDN scripts themselves fail, page code —
this module included, if bundled with the page — may never run. The pattern for that
case is a tiny dependency-free inline snippet in `<head>` that arms the same boot
timer before anything else loads. That snippet is a per-site integration artifact,
deliberately not part of this module.

### 5. Wire the sink

**Firestore (the starting sink for an app that already uses it):** the writer is
injected, so the module stays import-free and works with a compat SDK:

```js
var reporter = ErrorReporter.createReporter({
  site: 'example-app', release: RELEASE_SHA, sink: 'firestore',
  firestoreWriter: function (event) {
    return db.collection('error_reports').add(event); // a promise is fine — rejections are swallowed
  }
});
```

Adopters owe the Firestore rules for `error_reports`: create-only from clients,
no public reads.

**Websites (Worker):** `sink: 'worker'` + `workerUrl`, pointing at a small
validate-and-forward collector endpoint.

**Sentry (optional future swap):** load the real SDK first and initialise it
yourself — init (DSN, release) is the adopter's job and the `release` there should
match this module's `release` config:

```html
<script src="https://browser.sentry-cdn.com/<version>/bundle.min.js"></script>
<script> Sentry.init({ dsn: '…', release: '7509751' }); </script>
```

Then `sink: 'sentry'`. The adapter resolves `config.sentry` (an imported
`@sentry/browser` module) before the global, sends real Errors to
`captureException` and synthetic events (no Error object) to `captureMessage`, and maps
tiers to levels (0 → info, 1 → warning, 2 → error) with code/tier/area/site/release/
recovered tags and a fingerprint of `['{{ default }}', site, code, area]`.

**Demo/showroom/local:** `sink: 'none'`. **Tests:** `sink: 'memory'` + `getEvents()`.

### 6. Release stamp

Static sites stamp the deploy's commit SHA into the page when the snippet is
installed at build/deploy time, and pass it as the `release` config value, so every
event names the exact build that produced it.

## Library vs hand-rolled — with license, free-tier limits, and exit cost

Standing rule for this fleet: prefer proven open-source for anything non-trivial;
the boot/funnel core is the one deliberate exception; every adopted piece carries a
"limits & risk" line.

| Piece | Choice | License / limits & risk |
|---|---|---|
| Boot/funnel core, classifier, tier table, global handlers, boot flag | **Hand-rolled** (this module, ~2 files, zero dependencies) | By explicit exception: a dependency failing at boot is exactly the failure this system exists to catch. License: MIT (this repo). Limits: none. Risk: we own the bugs — mitigated by the test suite, incl. poisoned-sink. |
| Error grouping / fingerprinting | **Not hand-rolled.** Sentry sink: the platform's grouping + our fingerprint hint. DIY sinks: grouping is a reading-side job over `{site, code, area}` | No in-page library fits the never-throw core, and none is needed. Risk: DIY grouping quality is a reading-side build — bounded, since the key space is tiny. |
| Sentry (`@sentry/browser` + hosted service) | **Adopted as the optional sink's surface** — the adapter wraps the real `captureException`/`captureMessage` API; no forwarding protocol was invented | SDK license: **MIT**. Service (Developer/free): **5,000 error events/month, 1 seat, 30-day retention** (spans/replay quotas unused — tracing/replay are never initialised). **Risk:** a looping error can burn the monthly quota in an afternoon; past quota, events are *dropped* and alerting goes quiet — the design's deliberate-cancel drops and Tier 0/1 batching exist partly to protect this, and the in-page per-code throttle caps a loop at the source. If adopted for real, enable Sentry's spike protection too. Exit cost: change one config value and remove the SDK tag; the funnel, tiers, and event shape stay. Historical events stay in Sentry — with 30-day free retention, effectively nothing is stranded. Outgrow path: Team ≈ $26/mo for 50k errors. |
| Cloudflare Workers (collector host) | **Recommended** for the collector | Platform, no library license. Free: **100,000 requests/day, 10 ms CPU per invocation**, 50 subrequests/request. A validate-and-forward handler runs in ~1 ms CPU (I/O wait doesn't count), so CPU is not a real constraint; the daily request cap is the binding one. **Risk:** a runaway client loop eats a *day's* quota (resets midnight UTC) — same throttle mitigation as Sentry. Exit cost: the collector is one small endpoint taking plain JSON POSTs; re-hostable anywhere in an afternoon, and the log itself lives in the adopter's store, not Cloudflare's. Outgrow path: Paid $5/mo minimum, 10M requests/month included. |
| Worker routing | **Hono — recommended.** Evaluated alternative: itty-router | Hono: **MIT**, no quotas (it's a library), exit cost trivial (a bare `fetch` handler or itty-router — also MIT — is a drop-in at this size). Risk: negligible. Chosen for middleware ergonomics and momentum; itty-router remains a fine fallback. |
| UA parsing | **Not adopted.** ua-parser-js evaluated and **rejected on license**; Bowser is the fallback pick if ever needed | ua-parser-js **2.x is AGPLv3-or-commercial** (PRO $12–$500) — a copyleft trap for a fleet standard; its 1.x is MIT but unmaintained. Bowser 2.x: **MIT**, no quotas, exit trivial. Better still: no in-page parser is needed today — the event shape deliberately carries no UA; Sentry attaches browser context itself on that sink, and the Worker sees UA/Client-Hints headers server-side. |
| Retry / queue in-page | **Evaluated and rejected** (p-queue / p-retry class) | The contract is fire-and-forget: `sendBeacon`/fetch-keepalive is the platform's own delivery mechanism. A queue is mutable state that can throw, leak, and reorder — precisely what the core must never do, and a "delivered eventually" error report has little value over a dropped one. If a collector ever needs durable onward delivery, evaluate **Cloudflare Queues** then, server-side, where retries belong. |
| Test runner | **None** — plain Node script + `node:assert` | The suite is plain logic; a framework (Vitest/Jest) would be a dev-only dependency with its own maintenance, to test a module whose selling point is having no dependencies. Revisit if the suite outgrows a single file. |

### Fleet volume vs the free tiers — verdict

Expected volume for personal sites stays **comfortably inside both free tiers**:
normal error volume is single-digit events per day, and even a bad deploy week is
hundreds of events, not thousands — roughly 10–100× headroom under Sentry's
5,000/month, and orders of magnitude under Workers' 100,000/day. The one realistic
breach is not traffic but a *pathological loop* (one visitor's page firing errors
continuously), which is a correctness problem with a built mitigation (the per-code
throttle, section 3b), not a capacity plan.

## License

MIT — see the repo-root [LICENSE](../LICENSE).
