/*
 * error-reporter.js — visitor error reporting: the fleet-wide core module.
 *
 * Design: ../PROPOSAL.md. Classification policy: ./error-tiers.js (shared,
 * load it first or pass `tiers` in config). First adopter: the Family
 * Routines App (instrumentation map: ../INVENTORY.md).
 *
 * THE CONTRACT
 *   - One funnel: reportError(err, ctx). Host code never talks to a backend.
 *   - Emitted events have EXACTLY this shape, nothing else:
 *         { code, tier, area, operation, recovered, release, page, site, ts }
 *     (`operation` is the call-site operation name from ctx.operation, or
 *     null when the call site doesn't name one — amended from 8 fields to 9
 *     by Andrew's decision, Oct 29, 2026, before the first backfill.)
 *     No user data, nothing a visitor typed — ever.
 *   - Per-code throttle: within one page session, the first
 *     `throttlePerCode` occurrences of each code (default 10, config) are
 *     sent to the sink; further occurrences are counted, not sent. This is
 *     quota insurance against a pathological loop (Andrew's decision,
 *     Oct 29, 2026). Drop-class (deliberate) errors return before the
 *     throttle and never consume the cap. Suppressed counts live in
 *     reporter state only (getThrottleStats()) — no summary event is sent
 *     on unload: a flush would itself spend quota and can race teardown.
 *   - Tier 3 is never assigned here. It is earned only at the log (Q5).
 *   - THE REPORTER CAN NEVER THROW INTO THE HOST PAGE. Every path — funnel,
 *     classifier, sink dispatch, global handlers — is wrapped. A dead or
 *     hostile backend must be indistinguishable from a healthy one, as far
 *     as the app can tell. If you edit this file, preserve that property
 *     above all others; the poisoned-sink test in error-reporter.test.mjs
 *     exists to prove it.
 *
 * USAGE (browser)
 *   <script src="error-tiers.js"></script>
 *   <script src="error-reporter.js"></script>
 *   <script>
 *     ErrorReporter.configure({ site: 'showcase', release: 'abc1234', sink: 'worker',
 *                               workerUrl: 'https://errors.example.com/collect' });
 *     ErrorReporter.installGlobalHandlers();
 *     // after first successful render / subscribe:
 *     ErrorReporter.markBooted();
 *   </script>
 *
 * USAGE (app with injected Firestore writer — the module imports nothing)
 *   var reporter = ErrorReporter.createReporter({
 *     site: 'family-routines-app', release: RELEASE_SHA, sink: 'firestore',
 *     firestoreWriter: function (event) {
 *       return db.collection('error_reports').add(event); // promise is fine
 *     }
 *   });
 *   reporter.reportError(e, { area: 'tasks', operation: 'toggle-task' });
 */
(function (global) {
  'use strict';

  var DROP = -1; // internal sentinel: classify() returns this for "not an error"

  /* ---------------------------------------------------------------- helpers */

  function noop() {}

  function isThenable(v) {
    return v !== null && (typeof v === 'object' || typeof v === 'function') &&
      typeof v.then === 'function';
  }

  // Swallow a thenable's rejection so a failing async sink can never become
  // an unhandled rejection in the host page.
  function swallow(v) {
    try {
      if (isThenable(v)) {
        if (typeof v.catch === 'function') v.catch(noop);
        else v.then(noop, noop);
      }
    } catch (e) { /* the swallowing itself must not throw */ }
  }

  function safeNow() {
    try { return Date.now(); } catch (e) { return 0; }
  }

  function safePage() {
    try {
      if (global.location && typeof global.location.pathname === 'string') {
        return global.location.pathname;
      }
    } catch (e) { /* sandboxed frames etc. */ }
    return '';
  }

  /* ------------------------------------------------------- tier table access */

  // Minimal last-resort table, used only if error-tiers.js was neither loaded
  // nor passed in config AND the Node require below is unavailable. It exists
  // so the drop-class (deliberate cancels) is honoured even in a broken
  // deployment — silence about real errors is bad; logging a user's deliberate
  // cancel as a failure is worse. The full policy lives in error-tiers.js.
  var FALLBACK_TIERS = {
    'auth/popup-closed-by-user': { drop: true },
    'auth/cancelled-popup-request': { drop: true }
  };

  var sharedTiers = null;
  try {
    if (typeof module !== 'undefined' && module.exports &&
        typeof require === 'function') {
      sharedTiers = require('./error-tiers.js').ERROR_TIERS || null;
    }
  } catch (e) { sharedTiers = null; }

  // Resolved lazily (at first classification, not at load) so script order
  // between error-tiers.js and this file does not matter in the browser.
  function resolveTable(overrides) {
    var table = {};
    var base = sharedTiers ||
      (typeof global.ERROR_TIERS !== 'undefined' ? global.ERROR_TIERS : null) ||
      FALLBACK_TIERS;
    var k;
    for (k in base) if (Object.prototype.hasOwnProperty.call(base, k)) table[k] = base[k];
    if (overrides) {
      for (k in overrides) {
        if (Object.prototype.hasOwnProperty.call(overrides, k)) table[k] = overrides[k];
      }
    }
    return table;
  }

  /* ------------------------------------------------------------ error intake */

  // Extract the stable code. Firebase-style errors carry `.code`; DOM
  // exceptions and JS errors carry `.name`; anything else is 'unknown' and
  // will be classified purely by observable effect. Never stringify the raw
  // error into the event — codes and names only, so payloads stay small,
  // safe, and free of anything a visitor typed.
  function extractCode(err) {
    try {
      if (err === null || err === undefined) return 'unknown';
      if (typeof err === 'object' || typeof err === 'function') {
        if (typeof err.code === 'string' && err.code) return err.code;
        if (typeof err.name === 'string' && err.name && err.name !== 'Error') {
          return err.name;
        }
        return 'unknown';
      }
      return 'unknown'; // strings/numbers carry a message, not a code
    } catch (e) {
      return 'unknown';
    }
  }

  /* ------------------------------------------------------------ classification
   *
   * The proposal's five questions, in order. Q5 (fleet-wide promotion) is
   * log-side only and intentionally absent here.
   *
   * ctx signals (all optional):
   *   deliberate     true → Q1 drop, regardless of code.
   *   recovered      true → Q2 self-healed (Tier 0). 'pending' → a fallback
   *                  is in flight; classify by the unrecovered effect and
   *                  carry 'pending' in the event for log-side correlation.
   *   writeAmbiguous true → the write's outcome is unknowable client-side;
   *                  floors the tier at 1, overriding recovery (Q2 override).
   *   sessionDead    true → Q4, Tier 2.
   *   canContinue    false → the main thing is no longer doable → Tier 2.
   *   beforeBoot     true → error fired before the boot flag; for an unknown
   *                  code that means the app never became usable → Tier 2.
   */
  function classify(table, code, ctx) {
    // Q1 — deliberate user action: not an error, drop entirely.
    if (ctx.deliberate === true) return DROP;
    var entry = null;
    try { entry = table[code] || null; } catch (e) { entry = null; }
    if (entry && entry.drop === true) return DROP;

    // Q2 — a fallback recovered. (With an ambiguous write, "recovered" is
    // exactly what nobody knows — the override holds it at Tier 1.)
    if (ctx.recovered === true) {
      return ctx.writeAmbiguous === true ? 1 : 0;
    }

    // Q4 signals, checked before the table default: a dead session outranks
    // a code's expected tier.
    if (ctx.sessionDead === true || ctx.canContinue === false) return 2;

    // Known code: its expected tier from the shared table.
    if (entry && typeof entry.tier === 'number') {
      return ctx.writeAmbiguous === true ? Math.max(entry.tier, 1) : entry.tier;
    }

    // Unknown code: judge the observable effect only. Borderline resolves
    // toward logging (Tier 1), never toward silence.
    var tier = ctx.beforeBoot === true ? 2 : 1;
    if (ctx.writeAmbiguous === true) tier = Math.max(tier, 1);
    return tier;
  }

  /* ------------------------------------------------------------------- sinks
   *
   * A sink is send(event, rawErr). Only the Sentry adapter uses rawErr.
   * Every adapter is defensive on its own AND the dispatcher wraps the call,
   * so a sink gets two chances to fail safely.
   */
  function buildSink(config, memoryStore) {
    var sink = config.sink || 'none';

    if (typeof sink === 'function') {
      return { send: function (event) { return sink(event); } };
    }
    switch (sink) {
      case 'memory':
        return {
          send: function (event) { memoryStore.push(event); }
        };

      case 'firestore':
        // Lazy by construction: the module imports nothing. The host injects
        // a writer (in the app: (e) => db.collection('error_reports').add(e)).
        // A missing writer is a silent no-op, never an error.
        return {
          send: function (event) {
            if (typeof config.firestoreWriter === 'function') {
              return config.firestoreWriter(event);
            }
          }
        };

      case 'worker':
        return {
          send: function (event) {
            var url = config.workerUrl;
            if (!url) return;
            var body;
            try { body = JSON.stringify(event); } catch (e) { return; }
            try {
              if (global.navigator &&
                  typeof global.navigator.sendBeacon === 'function') {
                if (global.navigator.sendBeacon(url, body)) return;
              }
            } catch (e) { /* fall through to fetch */ }
            try {
              if (typeof global.fetch === 'function') {
                return global.fetch(url, {
                  method: 'POST',
                  body: body,
                  keepalive: true,
                  headers: { 'Content-Type': 'application/json' }
                });
              }
            } catch (e) { /* fire-and-forget means exactly that */ }
          }
        };

      case 'sentry':
        // Thin adapter over the REAL @sentry/browser surface — per the fleet
        // library rule, no hand-invented forwarding protocol. The SDK is
        // resolved, never imported: config.sentry (an injected @sentry/browser
        // module object, for bundled adopters) first, then the CDN bundle's
        // global `Sentry`. SDK init (dsn, release, environment) is the
        // adopter's job, done before configure(); this adapter only captures.
        // Real Errors go to captureException (full stack, SDK grouping);
        // synthetic events with no Error object (boot-timeout, resource-error,
        // bare {code} failures) go to captureMessage — the surface the SDK
        // provides for exactly those. The fingerprint appends site/code/area
        // to '{{ default }}' so a failure class groups together fleet-wide
        // without discarding the SDK's own stack-based grouping.
        return {
          send: function (event, rawErr) {
            var Sentry = null;
            if (config.sentry) Sentry = config.sentry;
            if (!Sentry) {
              try { Sentry = global.Sentry || null; } catch (e) { Sentry = null; }
            }
            if (!Sentry) return;
            var levels = { 0: 'info', 1: 'warning', 2: 'error' };
            var context = {
              level: levels[event.tier] || 'error',
              tags: {
                code: event.code,
                tier: String(event.tier),
                area: event.area,
                site: event.site,
                release: event.release,
                recovered: String(event.recovered)
              },
              fingerprint: ['{{ default }}', event.site, event.code, event.area]
            };
            if (rawErr instanceof Error &&
                typeof Sentry.captureException === 'function') {
              Sentry.captureException(rawErr, context);
            } else if (typeof Sentry.captureMessage === 'function') {
              Sentry.captureMessage(event.code, context);
            } else if (typeof Sentry.captureException === 'function') {
              var err = new Error(event.code);
              err.name = event.code;
              Sentry.captureException(err, context);
            }
          }
        };

      case 'none':
      default:
        return { send: noop };
    }
  }

  /* ---------------------------------------------------------------- reporter */

  function createReporter(config) {
    config = config || {};
    var table = resolveTable(config.tiers);
    var memoryStore = [];
    var sink = buildSink(config, memoryStore);
    var booted = false;
    var handlersInstalled = false;
    var bootTimer = null;

    // Per-code throttle state (per reporter instance = per page session).
    // throttlePerCode: occurrences of one code sent to the sink before the
    // rest are only counted. Default 10. A non-number or negative value
    // falls back to the default; Infinity disables the throttle. This state
    // must never be able to break the funnel — plain object, plain counts.
    var throttleCap = (typeof config.throttlePerCode === 'number' &&
      config.throttlePerCode >= 0)
      ? Math.floor(config.throttlePerCode) : 10;
    var throttleCounts = {}; // code -> { reported: n, suppressed: n }

    function isBooted() { return booted; }

    function markBooted() {
      booted = true;
      if (bootTimer !== null) {
        try { clearTimeout(bootTimer); } catch (e) {}
        bootTimer = null;
      }
    }

    // If the boot flag is not set within ms, the page never became a working
    // app: report it (Tier 2 via the boot-timeout entry). Returns nothing;
    // markBooted() disarms it. This is the in-module helper — the CDN-death
    // case additionally needs the dependency-free inline head snippet, which
    // is an integration artifact (see README), not part of this module.
    function armBootTimer(ms) {
      try {
        if (bootTimer !== null) clearTimeout(bootTimer);
        bootTimer = setTimeout(function () {
          bootTimer = null;
          if (!booted) {
            reportError({ code: 'boot-timeout' },
              { area: 'render', sessionDead: true, beforeBoot: true });
          }
        }, typeof ms === 'number' && ms > 0 ? ms : 10000);
        if (bootTimer && typeof bootTimer.unref === 'function') bootTimer.unref();
      } catch (e) { /* a timer must never break the page */ }
    }

    function classifyError(err, ctx) {
      try {
        ctx = ctx || {};
        var tier = classify(table, extractCode(err), ctx);
        return tier === DROP ? null : tier;
      } catch (e) {
        return 1; // classification itself failing resolves toward logging
      }
    }

    // THE FUNNEL. Returns the emitted event, or null if the error was
    // dropped (deliberate) — and null, quietly, if anything at all went
    // wrong inside the reporter. It cannot throw.
    function reportError(err, ctx) {
      try {
        ctx = ctx || {};
        var code = extractCode(err);
        var tier = classify(table, code, ctx);
        if (tier === DROP) return null;

        // Per-code throttle — deliberately AFTER the drop check, so
        // deliberate cancels never consume the cap. A suppressed occurrence
        // returns null exactly like a drop, except it is counted.
        var counts = throttleCounts[code];
        if (!counts) {
          counts = { reported: 0, suppressed: 0 };
          throttleCounts[code] = counts;
        }
        if (counts.reported >= throttleCap) {
          counts.suppressed += 1;
          return null;
        }
        counts.reported += 1;

        var event = {
          code: code,
          tier: tier,
          area: typeof ctx.area === 'string' && ctx.area ? ctx.area : 'unknown',
          operation: typeof ctx.operation === 'string' && ctx.operation
            ? ctx.operation : null,
          recovered: ctx.recovered === true ? true
            : (ctx.recovered === 'pending' ? 'pending' : false),
          release: typeof config.release === 'string' ? config.release : '',
          page: typeof ctx.page === 'string' ? ctx.page : safePage(),
          site: typeof config.site === 'string' ? config.site : '',
          ts: safeNow()
        };

        try {
          swallow(sink.send(event, err));
        } catch (e) { /* a dead sink is indistinguishable from a healthy one */ }

        return event;
      } catch (e) {
        return null;
      }
    }

    /* ------------------------------------------------------ global handlers */

    // Installs the last-resort net (inventory S3): runtime errors WITH the
    // full error object, unhandled promise rejections, and resource-load
    // failures. Accepts an optional event target (defaults to the global
    // window) so tests and non-window hosts can inject one. Observation
    // only: nothing is preventDefault-ed, nothing is rethrown.
    function installGlobalHandlers(target) {
      try {
        var t = target || global;
        if (!t || typeof t.addEventListener !== 'function') return false;
        if (handlersInstalled) return true;
        handlersInstalled = true;

        // Runtime errors (non-capture): ErrorEvent.error is the full object.
        t.addEventListener('error', function (e) {
          try {
            if (!e) return;
            // Resource failures have an element target and no .error; the
            // capture listener below owns those — skip them here so nothing
            // is double-reported.
            if (e.target && e.target !== t) return;
            if (e.error) {
              reportError(e.error, {
                area: 'render', source: 'window.onerror', beforeBoot: !booted
              });
            } else if (typeof e.message === 'string' && e.message) {
              // Cross-origin opaque error: no object survives, count it.
              reportError({ code: 'script-error' }, {
                area: 'render', source: 'window.onerror', beforeBoot: !booted
              });
            }
          } catch (ignored) {}
        }, false);

        // Resource errors (capture phase — they do not bubble): script,
        // stylesheet, and image loads that failed.
        t.addEventListener('error', function (e) {
          try {
            if (!e || !e.target || e.target === t) return;
            var el = e.target;
            var url = (typeof el.src === 'string' && el.src) ||
                      (typeof el.href === 'string' && el.href) || '';
            if (!url) return;
            reportError({ code: 'resource-error' }, {
              area: 'render', source: 'resource', resourceUrl: url,
              beforeBoot: !booted
            });
          } catch (ignored) {}
        }, true);

        // The hole in the app's current net: rejected promises nobody caught.
        t.addEventListener('unhandledrejection', function (e) {
          try {
            var reason = e ? e.reason : undefined;
            reportError(reason === undefined ? { code: 'unknown' } : reason, {
              area: 'unknown', source: 'unhandledrejection', beforeBoot: !booted
            });
          } catch (ignored) {}
        }, false);

        return true;
      } catch (e) {
        return false;
      }
    }

    return {
      reportError: reportError,
      classifyError: classifyError,
      installGlobalHandlers: installGlobalHandlers,
      markBooted: markBooted,
      isBooted: isBooted,
      armBootTimer: armBootTimer,
      // Test/inspection access to the memory sink's store.
      getEvents: function () { return memoryStore.slice(); },
      clearEvents: function () { memoryStore.length = 0; },
      // Per-code throttle state: { code: { reported, suppressed } }. This is
      // the ONLY place suppressed counts surface — by design no summary
      // event is emitted on unload (see the contract note at the top).
      getThrottleStats: function () {
        var out = {};
        for (var k in throttleCounts) {
          if (Object.prototype.hasOwnProperty.call(throttleCounts, k)) {
            out[k] = {
              reported: throttleCounts[k].reported,
              suppressed: throttleCounts[k].suppressed
            };
          }
        }
        return out;
      },
      config: {
        site: typeof config.site === 'string' ? config.site : '',
        release: typeof config.release === 'string' ? config.release : '',
        sink: typeof config.sink === 'string' ? config.sink : 'custom',
        throttlePerCode: throttleCap
      }
    };
  }

  /* ------------------------------------------------------- default singleton */

  var defaultReporter = createReporter({ sink: 'none' });

  function configure(cfg) {
    try { defaultReporter = createReporter(cfg || {}); } catch (e) { /* keep the old one */ }
    return defaultReporter;
  }

  var api = {
    createReporter: createReporter,
    configure: configure,
    reportError: function (err, ctx) { return defaultReporter.reportError(err, ctx); },
    classifyError: function (err, ctx) { return defaultReporter.classifyError(err, ctx); },
    installGlobalHandlers: function (t) { return defaultReporter.installGlobalHandlers(t); },
    markBooted: function () { defaultReporter.markBooted(); },
    isBooted: function () { return defaultReporter.isBooted(); },
    armBootTimer: function (ms) { defaultReporter.armBootTimer(ms); },
    getDefaultReporter: function () { return defaultReporter; },
    DROP: DROP
  };

  global.ErrorReporter = api;
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
