/*
 * error-tiers.js — the fleet-wide classification table for visitor error reporting.
 *
 * This file is the SHARED POLICY for every app and website in the fleet
 * (see ../PROPOSAL.md). It is deliberately a separate file from the reporter so a
 * single copy can ship with the kit and every adopter classifies identically.
 * Load it BEFORE error-reporter.js, or pass it explicitly as `tiers` in the
 * reporter config — both work; the reporter also merges per-site overrides.
 *
 * Entry shapes:
 *   { drop: true }  — Q1 of the heuristic: a deliberate user action, NOT an error.
 *                     Dropped entirely: never logged, never counted.
 *   { tier: 0|1|2 } — the code's expected tier when no stronger effect signal
 *                     is present at the call site.
 *
 * Tier meanings (routing lives on the reading side, not in this table):
 *   0 = self-healed by a fallback; count only.
 *   1 = visible failure, user can still do the main thing.
 *   2 = one user stuck; session effectively dead.
 * Tier 3 (broken for everyone) is NEVER assigned here or anywhere in the page —
 * it is earned only at the log, from aggregate signals (proposal Q5).
 *
 * The table is a DEFAULT, not a verdict. The reporter's classifier always lets
 * observable effect override it:
 *   - recovered === true          → Tier 0 (unless the write was ambiguous)
 *   - ctx.writeAmbiguous === true → at least Tier 1
 *   - ctx.sessionDead === true
 *     or ctx.canContinue === false → Tier 2
 * Codes NOT listed here are not ignored — they are classified purely by those
 * effect signals (default Tier 1; Tier 2 if the session is dead or the error
 * fired before the boot flag).
 *
 * Seeding: codes marked [inventory] come from the Family Routines App Phase 0
 * survey (../INVENTORY.md, site ids in the notes). Codes marked [standard] are
 * ordinary Firebase/DOM codes added on the same effect reasoning, not from the
 * survey. When in doubt about a new code, leave it OUT — the heuristic will
 * place it by effect, and the log will teach us where it belongs.
 */
(function (global) {
  'use strict';

  var ERROR_TIERS = {

    /* ------------------------------------------------------------------
     * DROP CLASS — deliberate user actions (heuristic Q1). Not errors.
     * ------------------------------------------------------------------ */
    'auth/popup-closed-by-user': {
      drop: true,
      note: '[inventory S4] The user closed the sign-in popup themselves.'
    },
    'auth/cancelled-popup-request': {
      drop: true,
      note: '[inventory S4] A second popup request superseded the first; the cancel is the app working as designed.'
    },

    /* ------------------------------------------------------------------
     * AUTH (Firebase Authentication)
     * ------------------------------------------------------------------ */
    'auth/popup-blocked': {
      tier: 0,
      note: '[inventory S4] The browser blocked the popup and the redirect fallback is the designed recovery. Report with ctx.recovered = "pending" at fire time; if the redirect itself fails, the fallback site (S6) files its own Tier 2 report — this entry is the count of the self-heal working.'
    },
    'auth/network-request-failed': {
      tier: 1,
      note: '[inventory S4/S6] Transient until proven otherwise: ctx.recovered === true downgrades to Tier 0; if it kills sign-in or a session, the call site passes sessionDead and it classifies Tier 2.'
    },
    'auth/unauthorized-domain': {
      tier: 2,
      note: '[inventory S4] Config-class: the fallback cannot fix it and every visitor on this domain hits it. Prime Tier 3 candidate at the log.'
    },
    'auth/operation-not-allowed': {
      tier: 2,
      note: '[inventory S4/S7] Config-class: provider not enabled. Every visitor hits it.'
    },
    'auth/internal-error': {
      tier: 2,
      note: '[inventory S4] Auth backend/config failure the fallback cannot route around.'
    },
    'auth/api-key-not-valid': {
      tier: 2,
      note: '[inventory S2] Almost always deploy-borne (e.g. the __FIREBASE_API_KEY__ placeholder shipped unsubstituted). The release stamp on the event identifies the bad deploy.'
    },
    'auth/account-exists-with-different-credential': {
      tier: 2,
      note: '[inventory S7] Raised on return from redirect sign-in; the user is bounced back to a signed-out screen with no path forward in the app.'
    },
    'auth/credential-already-in-use': {
      tier: 2,
      note: '[inventory S7] Same shape as account-exists: sign-in cannot complete.'
    },
    'auth/user-disabled': {
      tier: 2,
      note: '[standard] The account is disabled; sign-in cannot complete by any in-app path.'
    },

    /* ------------------------------------------------------------------
     * FIRESTORE — bare codes, shared by every operation, so these are
     * deliberately conservative defaults. The call site's effect signals
     * (area, sessionDead, canContinue, writeAmbiguous) do the real placing:
     * permission-denied on a cosmetic listener is Tier 1, while the SAME
     * code on provisioning or pre-first-snapshot tasks is Tier 2 by ctx.
     * ------------------------------------------------------------------ */
    'permission-denied': {
      tier: 1,
      note: '[inventory S9/S10/S15–S26] Rules or auth mismatch. Escalates to Tier 2 via ctx where the effect is a dead session (provisioning S13, profile load S10, tasks before first snapshot S16, admin registry S9). A rules regression shows up at the log as this code spiking across users — a Tier 3 pattern.'
    },
    'unavailable': {
      tier: 1,
      note: '[inventory passim] Backend unreachable / offline. For writes the compat SDK does not queue, so call sites pair it with ctx.writeAmbiguous when local state was already mutated (S17/S19/S21–S25).'
    },
    'aborted': {
      tier: 1,
      note: '[inventory S26] Transaction contention. Usually transient; if a later evaluation credits the completion, the log-side resolution downgrades the incident.'
    },
    'deadline-exceeded': {
      tier: 1,
      note: '[inventory S13/S26] Timed out. For transactions and batches the outcome may be unknowable client-side — pass ctx.writeAmbiguous so the ambiguous-write override holds it at Tier 1 minimum.'
    },
    'not-found': {
      tier: 1,
      note: '[inventory S21] E.g. updating a task another device already deleted. Self-resolves on the next snapshot.'
    },
    'invalid-argument': {
      tier: 1,
      note: '[inventory S22] A write the backend rejects as malformed; the user\u2019s input or edit is lost unless the UI kept it.'
    },
    'resource-exhausted': {
      tier: 1,
      note: '[standard] Quota/rate exhaustion. Worth its own code in the weekly counts — a rising rate is a capacity signal, not a bug spike.'
    },
    'failed-precondition': {
      tier: 1,
      note: '[standard] Operation rejected by current state (e.g. a transaction precondition). Judged Tier 1 by effect: visible, user can continue.'
    },
    'unauthenticated': {
      tier: 2,
      note: '[standard] The client\u2019s auth token is gone/invalid for a data operation; until re-auth the session is effectively dead for data.'
    },

    /* ------------------------------------------------------------------
     * MODULE-SYNTHETIC codes — emitted by the reporter itself or by the
     * instrumentation the inventory prescribes, not by any library.
     * ------------------------------------------------------------------ */
    'watchdog-fired': {
      tier: 0,
      note: '[inventory S5] The 10s sign-in popup watchdog fired and started the redirect fallback. Tier 0 when the redirect completes (ctx.recovered); the event exists so a rising rate is visible at the log (a browser update breaking popups is a Tier 3 pattern).'
    },
    'boot-timeout': {
      tier: 2,
      note: '[inventory S1/S2 + proposal boot flag] The boot flag was not set within the armed window: the page never became a working app (dead CDN script, init throw, blocked SDK). Session dead by definition.'
    },
    'resource-error': {
      tier: 1,
      note: '[inventory S1] A script/stylesheet/image failed to load, reported by the capture-phase resource listener. A failed decorative asset and a failed SDK both land here from the listener\u2019s viewpoint; the boot flag separates them (SDK death also produces boot-timeout).'
    },
    'script-error': {
      tier: 1,
      note: '[inventory S1/S3] Opaque cross-origin error ("Script error.") — the browser withholds code, stack, and origin by design. Only the count is meaningful; beforeBoot escalates it via the heuristic.'
    },

    /* ------------------------------------------------------------------
     * BROWSER / DOM exception names (arrive via err.name, no .code).
     * ------------------------------------------------------------------ */
    'SecurityError': {
      tier: 1,
      note: '[inventory S33] Storage blocked (or a non-secure-context API). The app works; the first-paint cache and recovery correlation degrade.'
    },
    'QuotaExceededError': {
      tier: 1,
      note: '[inventory S33] localStorage full/blocked on write. Same effect class as SecurityError.'
    },
    'NotAllowedError': {
      tier: 0,
      note: '[inventory S34/S35] Clipboard write or similar permission-gated API refused. Diagnostics-surface only; count it, never page on it.'
    }
  };

  global.ERROR_TIERS = ERROR_TIERS;
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { ERROR_TIERS: ERROR_TIERS };
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
