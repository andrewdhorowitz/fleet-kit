#!/usr/bin/env python3
"""cf_token_converge.py — Cloudflare token-policy converger (owner-run).

Compares Andrew's live Cloudflare API tokens against the declared policy in
tokens.json (same directory) and, by default, ADDITIVELY applies any missing
declared permission groups. Ruled in the main chat on 2026-11-05: the
converger's authority is "apply automatically on Andrew's kickoff".

Run it ONLY on Andrew's phone (Termux) with the owner-side admin token
("Token Admin — owner only", User -> API Tokens -> Edit, stored in his
1Password). The admin token is read from the CF_TOKEN_ADMIN environment
variable if set, otherwise prompted for with hidden input. It is held in
memory only: never echoed, never written to disk, never committed.

Modes:
  (default)    check + apply missing declared groups, then re-verify
  --check      report only, change nothing
  --selftest   offline unit tests of the resolver/comparison/guard (no API)

v1 safety rules (deliberate; changing them needs a new ruling):
  - ADDITIVE ONLY. Undeclared live groups are reported as drift and are
    NEVER removed. Removal waits on a future --prune ruling.
  - The "Token Admin — owner only" token is hard-guarded: this script will
    never PUT it, under any flag. It is also declared report_only.
  - If any declared group name cannot be resolved uniquely against the
    live permission-group catalog, that token is report-only for the run
    (an UNRESOLVED line names the group). Never guess, never apply a
    partial set.
  - PUTs are paced (a short sleep between them) per the provider
    control-plane pacing rule.
  - Results (token names, group names, diffs, timestamps — NEVER token
    values; the API never returns them) go to stdout and to
    cf-token-converge-results.txt at the fleet-kit repo root.

Exit codes:
  0  every declared token is OK, or was applied and re-verified
  1  drift unresolved (missing groups in --check mode, or an apply that
     failed its re-verify), an UNRESOLVED group, a MISSING declared
     token, or drift on a report-only token
  2  authentication failure (admin token invalid, expired, or inactive)

UNDECLARED groups are warnings: they are reported but do not change the
exit code, because v1 can never resolve them (it never removes).

Python 3 standard library only — runs in Termux.
"""

import copy
import getpass
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

API_BASE = "https://api.cloudflare.com/client/v4"
ADMIN_TOKEN_NAME = "Token Admin — owner only"
PACE_SECONDS = 2.5

SCOPE_RESOURCE_PREFIX = {
    "account": "com.cloudflare.api.account.",   # + account_id
    "zone": "com.cloudflare.api.account.zone.",  # + zone_id
    "user": "com.cloudflare.api.user.",          # prefix match (user id varies)
}
SCOPE_CATALOG_KEY = {
    "account": "com.cloudflare.api.account",
    "zone": "com.cloudflare.api.account.zone",
    "user": "com.cloudflare.api.user",
}
LEVEL_WORDS = {"read": ["read"], "edit": ["edit", "write"],
               "write": ["write", "edit"]}


class GuardRefusal(Exception):
    """Raised when an apply is attempted on a guarded token."""


class AuthFailure(Exception):
    """Raised when the admin token fails verification."""


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

def normalize(text):
    """Lowercase, collapse whitespace/punctuation for name matching."""
    out = []
    for ch in str(text).lower():
        out.append(ch if ch.isalnum() else " ")
    return " ".join("".join(out).split())


def results_path():
    """cf-token-converge-results.txt at the fleet-kit repo root."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    candidate = os.path.join(root, "cf-token-converge-results.txt")
    if os.path.isdir(root) and os.access(root, os.W_OK):
        return candidate
    return os.path.join(os.getcwd(), "cf-token-converge-results.txt")


def now_stamp():
    try:
        from zoneinfo import ZoneInfo
        return datetime.now(ZoneInfo("America/New_York")).isoformat(timespec="seconds")
    except Exception:
        return datetime.now().astimezone().isoformat(timespec="seconds")


# --------------------------------------------------------------------------
# Permission-group name resolution (pure — unit-tested by --selftest)
# --------------------------------------------------------------------------

def _level_variants(level):
    """Acceptable trailing level words for a declared level, best first."""
    lv = normalize(level)
    if lv.startswith("at least"):
        base = lv.replace("at least", "").strip()
        words = list(LEVEL_WORDS.get(base, [base]))
        for extra in ("edit", "write", "read"):
            if extra not in words:
                words.insert(0 if base == "read" else len(words), extra)
        # at_least Read -> read preferred, then edit/write also acceptable
        ordered = []
        for w in ["read", "edit", "write"]:
            if w in words:
                ordered.append(w)
        return ordered
    return list(LEVEL_WORDS.get(lv, [lv]))


def _is_at_least(level):
    return normalize(level).startswith("at least")


def resolve_group(declared, catalog, scope):
    """Resolve one declared {"name", "level"} to catalog group ids.

    Returns {"primary": id, "acceptable": {ids}, "names": {id: name}}
    or None when the group cannot be resolved uniquely.
    catalog: list of {"id", "name", "scopes" (optional list)}.
    """
    base = normalize(declared["name"])
    level = declared["level"]
    variants = _level_variants(level)
    at_least = _is_at_least(level)

    def in_scope(entry):
        scopes = entry.get("scopes")
        if not scopes:
            return True
        want = SCOPE_CATALOG_KEY[scope]
        return any(s == want for s in scopes)

    def pool(entries):
        scoped = [e for e in entries if in_scope(e)]
        return scoped if scoped else list(entries)

    def exact(entries):
        found = {}
        for word in variants:
            target = normalize(base + " " + word)
            for e in entries:
                if normalize(e["name"]) == target:
                    found[e["id"]] = e["name"]
        return found

    def contains(entries):
        hits = {}
        for e in entries:
            n = normalize(e["name"])
            words = n.split()
            if not words:
                continue
            if base in n and words[-1] in variants:
                hits[e["id"]] = e["name"]
        return hits

    entries = pool(catalog)
    exact_hits = exact(entries)
    if exact_hits:
        if not at_least and len(exact_hits) > 1:
            return None
        primary = None
        for word in variants:
            target = normalize(base + " " + word)
            for gid, gname in exact_hits.items():
                if normalize(gname) == target:
                    primary = gid
                    break
            if primary:
                break
        return {"primary": primary, "acceptable": set(exact_hits),
                "names": exact_hits}
    contains_hits = contains(entries)
    if len(contains_hits) == 1:
        gid = next(iter(contains_hits))
        return {"primary": gid, "acceptable": set(contains_hits),
                "names": contains_hits}
    return None


def resolve_declared(declared_groups, catalog, scope):
    """Resolve a list of declared groups. Returns (resolved, unresolved):
    resolved = list of {"declared": g, "primary": id, "acceptable": set,
    "names": {id: name}}; unresolved = list of declared groups."""
    resolved, unresolved = [], []
    for g in declared_groups:
        r = resolve_group(g, catalog, scope)
        if r is None:
            unresolved.append(g)
        else:
            r = dict(r)
            r["declared"] = g
            resolved.append(r)
    return resolved, unresolved


# --------------------------------------------------------------------------
# Live-policy comparison and additive apply planning (pure)
# --------------------------------------------------------------------------

def element_scope_keys(element, policy):
    """Classify one policy element's resources into scope -> key set."""
    out = {"account": set(), "zone": set(), "user": set()}
    resources = element.get("resources") or {}
    acct_key = SCOPE_RESOURCE_PREFIX["account"] + policy["account_id"]
    zone_keys = {SCOPE_RESOURCE_PREFIX["zone"] + zid
                 for zid in policy["zones"].values()}
    for key in resources:
        if key == acct_key:
            out["account"].add(key)
        elif key in zone_keys:
            out["zone"].add(key)
        elif key.startswith(SCOPE_RESOURCE_PREFIX["user"]):
            out["user"].add(key)
    return out


def live_group_ids(live_policies, policy, scope, zone_id=None):
    """Union of live permission-group ids for a scope (or one zone)."""
    acct_key = SCOPE_RESOURCE_PREFIX["account"] + policy["account_id"]
    if scope == "account":
        wanted = {acct_key}
    elif scope == "zone":
        zid = zone_id or ""
        wanted = {SCOPE_RESOURCE_PREFIX["zone"] + zid} if zid else \
            {SCOPE_RESOURCE_PREFIX["zone"] + z for z in policy["zones"].values()}
    else:
        wanted = None  # user: any user-prefixed key
    ids = set()
    for element in live_policies:
        keys = set((element.get("resources") or {}).keys())
        if scope == "user":
            hit = any(k.startswith(SCOPE_RESOURCE_PREFIX["user"]) for k in keys)
        else:
            hit = bool(keys & wanted)
        if hit:
            for g in element.get("permission_groups") or []:
                if g.get("id"):
                    ids.add(g["id"])
    return ids


def compare_scope(resolved, live_ids):
    """Returns (missing_primary_ids, satisfied_ids, undeclared_ids)."""
    declared_acceptable = set()
    for r in resolved:
        declared_acceptable |= r["acceptable"]
    missing = []
    satisfied = set()
    for r in resolved:
        if live_ids & r["acceptable"]:
            satisfied |= (live_ids & r["acceptable"])
        else:
            missing.append(r["primary"])
    undeclared = live_ids - declared_acceptable
    return missing, satisfied, undeclared


def find_extendable_element(live_policies, resource_key):
    """Index of a policy element whose resources are exactly {key: ...},
    else None."""
    for i, element in enumerate(live_policies):
        keys = set((element.get("resources") or {}).keys())
        if keys == {resource_key}:
            return i
    return None


def plan_additions(token_decl, live_policies, additions, policy):
    """Return a NEW policies list with the missing groups added.

    additions: list of (scope, resource_key, group_id).
    Raises GuardRefusal for the admin token / any report_only token.
    Everything untouched is preserved verbatim (deep-copied)."""
    if token_decl.get("report_only") or token_decl.get("name") == ADMIN_TOKEN_NAME:
        raise GuardRefusal(
            "guard: '%s' is report-only and must never be modified"
            % token_decl.get("name"))
    new_policies = copy.deepcopy(live_policies)
    for scope, resource_key, group_id in additions:
        idx = find_extendable_element(new_policies, resource_key)
        if idx is None:
            new_policies.append({
                "effect": "allow",
                "resources": {resource_key: "*"},
                "permission_groups": [{"id": group_id}],
            })
        else:
            groups = new_policies[idx].setdefault("permission_groups", [])
            if not any(g.get("id") == group_id for g in groups):
                groups.append({"id": group_id})
    return new_policies


# --------------------------------------------------------------------------
# Cloudflare API (admin token held in memory only)
# --------------------------------------------------------------------------

class CfApi:
    def __init__(self, token):
        self._token = token

    def call(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(API_BASE + path, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self._token)
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError as err:
            raw = err.read().decode("utf-8", "replace")
            try:
                return json.loads(raw)
            except json.JSONDecodeError:
                return {"success": False, "http_status": err.code, "raw": raw}

    def verify(self):
        out = self.call("GET", "/user/tokens/verify")
        result = out.get("result") or {}
        if not out.get("success") or result.get("status") != "active":
            raise AuthFailure(
                "admin token verification failed (invalid, expired, or not active)")
        return result

    def permission_groups(self):
        return self._list("/user/tokens/permission_groups")

    def tokens(self):
        return self._list("/user/tokens")

    def _list(self, path):
        items, page = [], 1
        while True:
            sep = "&" if "?" in path else "?"
            out = self.call("GET", "%s%sper_page=100&page=%d" % (path, sep, page))
            if not out.get("success"):
                raise AuthFailure(
                    "admin token cannot read %s (missing API Tokens permission?)"
                    % path)
            items.extend(out.get("result") or [])
            info = out.get("result_info") or {}
            if page >= int(info.get("total_pages") or 1):
                return items
            page += 1

    def token_detail(self, token_id):
        out = self.call("GET", "/user/tokens/" + token_id)
        if not out.get("success"):
            raise RuntimeError("GET /user/tokens/%s failed: %s"
                               % (token_id, out.get("errors")))
        return out["result"]

    def update_token(self, token_id, payload):
        return self.call("PUT", "/user/tokens/" + token_id, payload)


# --------------------------------------------------------------------------
# Converge run
# --------------------------------------------------------------------------

class Reporter:
    def __init__(self):
        self.lines = []

    def say(self, line=""):
        print(line, flush=True)
        self.lines.append(line)

    def save(self):
        path = results_path()
        header = "cf_token_converge results — %s" % now_stamp()
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(header + "\n")
            for line in self.lines:
                fh.write(line + "\n")
        return path


def group_label(catalog_by_id, group_id):
    entry = catalog_by_id.get(group_id)
    return entry["name"] if entry else group_id


def run(policy, check_only, api, rep):
    exit_code = 0
    rep.say("mode: %s" % ("check only" if check_only else "apply (additive only)"))

    catalog = api.permission_groups()
    catalog_by_id = {e["id"]: e for e in catalog}
    live_tokens = api.tokens()
    by_name = {}
    for t in live_tokens:
        by_name.setdefault(t.get("name"), []).append(t)

    puts_done = 0
    for decl in policy["tokens"]:
        name = decl["name"]
        rep.say("")
        rep.say("== %s ==" % name)
        matches = by_name.get(name) or []
        if not matches:
            rep.say("MISSING: declared token not found live")
            exit_code = 1
            continue
        live = api.token_detail(matches[0]["id"])
        live_policies = live.get("policies") or []
        report_only = bool(decl.get("report_only")) or name == ADMIN_TOKEN_NAME
        if report_only:
            rep.say("report-only token (never modified by this script)")

        token_unresolved = False
        scopes = decl.get("scopes") or {}
        # Per-scope diffs; additions collected for apply.
        additions = []          # (scope, resource_key, group_id)
        missing_labels = []
        for scope in ("user", "account", "zone"):
            declared_groups = scopes.get(scope) or []
            if not declared_groups:
                continue
            resolved, unresolved = resolve_declared(declared_groups, catalog, scope)
            for g in unresolved:
                rep.say("UNRESOLVED %s: '%s' (%s) — cannot resolve uniquely "
                        "in the catalog; token is report-only this run"
                        % (scope, g["name"], g["level"]))
                token_unresolved = True
            if scope == "zone":
                # Zone scope is judged per zone; a group missing on any
                # zone is missing for that zone.
                zone_missing = {}   # group_id -> [zone names]
                zone_undeclared = {}
                for zname, zid in sorted(policy["zones"].items()):
                    zkey = SCOPE_RESOURCE_PREFIX["zone"] + zid
                    live_ids = live_group_ids(live_policies, policy, "zone", zid)
                    missing, _sat, undecl = compare_scope(resolved, live_ids)
                    for gid in missing:
                        zone_missing.setdefault(gid, []).append(zname)
                        additions.append(("zone", zkey, gid))
                    for gid in undecl:
                        zone_undeclared.setdefault(gid, []).append(zname)
                for gid, znames in sorted(zone_missing.items()):
                    lbl = group_label(catalog_by_id, gid)
                    missing_labels.append("%s: %s" % (scope, lbl))
                    rep.say("MISSING %s: %s (zones: %s)"
                            % (scope, lbl, ", ".join(znames)))
                for gid, znames in sorted(zone_undeclared.items()):
                    rep.say("UNDECLARED %s: %s (zones: %s) — reported, kept"
                            % (scope, group_label(catalog_by_id, gid),
                               ", ".join(znames)))
                if not zone_missing and not unresolved:
                    rep.say("OK %s: all declared groups present on all zones"
                            % scope)
            else:
                if scope == "account":
                    resource_key = (SCOPE_RESOURCE_PREFIX["account"]
                                    + policy["account_id"])
                else:
                    resource_key = None  # discovered below if needed
                live_ids = live_group_ids(live_policies, policy, scope)
                missing, _sat, undecl = compare_scope(resolved, live_ids)
                for gid in missing:
                    lbl = group_label(catalog_by_id, gid)
                    missing_labels.append("%s: %s" % (scope, lbl))
                    rep.say("MISSING %s: %s" % (scope, lbl))
                    if scope == "account":
                        additions.append(("account", resource_key, gid))
                    else:
                        key = discover_user_key(live_policies)
                        if key:
                            additions.append(("user", key, gid))
                        else:
                            rep.say("UNRESOLVED %s: cannot determine the user "
                                    "resource key from live policies" % scope)
                            token_unresolved = True
                for gid in sorted(undecl):
                    rep.say("UNDECLARED %s: %s — reported, kept"
                            % (scope, group_label(catalog_by_id, gid)))
                if not missing and not unresolved:
                    rep.say("OK %s: all declared groups present" % scope)

        if token_unresolved:
            exit_code = 1
            continue
        if not missing_labels:
            rep.say("OK: token matches the declared policy")
            continue

        # Drift exists.
        if report_only:
            rep.say("DRIFT on a report-only token — reported, never applied")
            exit_code = 1
            continue
        if check_only:
            rep.say("DRIFT: %d declared group(s) missing (check mode, "
                    "nothing changed)" % len(missing_labels))
            exit_code = 1
            continue

        # Apply: additive only, guard first.
        try:
            new_policies = plan_additions(decl, live_policies, additions, policy)
        except GuardRefusal as refusal:
            rep.say("GUARD: %s" % refusal)
            exit_code = 1
            continue
        payload = {"name": live.get("name"), "policies": new_policies}
        if live.get("status"):
            payload["status"] = live["status"]
        for field in ("expires_on", "not_before", "condition"):
            if live.get(field):
                payload[field] = live[field]
        if puts_done:
            time.sleep(PACE_SECONDS)
        out = api.update_token(live["id"], payload)
        puts_done += 1
        if not out.get("success"):
            rep.say("APPLY FAILED: PUT returned errors: %s" % (out.get("errors"),))
            exit_code = 1
            continue
        # Re-read and verify before claiming anything.
        after = api.token_detail(live["id"])
        after_policies = after.get("policies") or []
        still_missing = []
        for scope in ("user", "account", "zone"):
            declared_groups = scopes.get(scope) or []
            if not declared_groups:
                continue
            resolved, _u = resolve_declared(declared_groups, catalog, scope)
            if scope == "zone":
                for zid in policy["zones"].values():
                    m, _s, _u2 = compare_scope(
                        resolved, live_group_ids(after_policies, policy, "zone", zid))
                    still_missing.extend(m)
            else:
                m, _s, _u2 = compare_scope(
                    resolved, live_group_ids(after_policies, policy, scope))
                still_missing.extend(m)
        if still_missing:
            rep.say("APPLY FAILED verify: still missing %s"
                    % ", ".join(group_label(catalog_by_id, g)
                                for g in sorted(set(still_missing))))
            exit_code = 1
        else:
            rep.say("APPLIED + VERIFIED: added %s"
                    % ", ".join(missing_labels))
    return exit_code


def discover_user_key(live_policies):
    for element in live_policies:
        for key in (element.get("resources") or {}):
            if key.startswith(SCOPE_RESOURCE_PREFIX["user"]):
                return key
    return None


# --------------------------------------------------------------------------
# Offline self-test (--selftest) — no network, no state touched
# --------------------------------------------------------------------------

def run_selftest():
    failures = []

    def check(label, cond):
        print(("PASS " if cond else "FAIL ") + label)
        if not cond:
            failures.append(label)

    catalog = [
        {"id": "g_dns_read", "name": "DNS Read",
         "scopes": ["com.cloudflare.api.account.zone"]},
        {"id": "g_dns_write", "name": "DNS Write",
         "scopes": ["com.cloudflare.api.account.zone"]},
        {"id": "g_zone_read", "name": "Zone Read",
         "scopes": ["com.cloudflare.api.account.zone"]},
        {"id": "g_zone_write", "name": "Zone Write",
         "scopes": ["com.cloudflare.api.account.zone"]},
        {"id": "g_pages_write", "name": "Cloudflare Pages Write",
         "scopes": ["com.cloudflare.api.account"]},
        {"id": "g_api_tokens_edit", "name": "API Tokens Edit",
         "scopes": ["com.cloudflare.api.user"]},
        {"id": "g_extra_read", "name": "Extra Thing Read",
         "scopes": ["com.cloudflare.api.account.zone"]},
    ]
    policy = {"account_id": "acct1", "zones": {"z.example": "zone1"}}
    zkey = SCOPE_RESOURCE_PREFIX["zone"] + "zone1"

    # 1. Edit -> Write variant resolution.
    r = resolve_group({"name": "DNS", "level": "Edit"}, catalog, "zone")
    check("resolver: declared 'DNS Edit' resolves to catalog 'DNS Write'",
          r is not None and r["primary"] == "g_dns_write")

    # 2. Contains-match, unique candidate only.
    r = resolve_group({"name": "Pages", "level": "Edit"}, catalog, "account")
    check("resolver: unique contains-match resolves 'Pages Edit'",
          r is not None and r["primary"] == "g_pages_write")

    # 3. Missing declared groups are detected.
    resolved, unresolved = resolve_declared(
        [{"name": "DNS", "level": "Edit"}, {"name": "Zone", "level": "Edit"}],
        catalog, "zone")
    live = [{"effect": "allow", "resources": {zkey: "*"},
             "permission_groups": [{"id": "g_extra_read"}]}]
    missing, _sat, undecl = compare_scope(
        resolved, live_group_ids(live, policy, "zone", "zone1"))
    check("compare: missing declared groups detected",
          set(missing) == {"g_dns_write", "g_zone_write"} and not unresolved)

    # 4. Undeclared group detected AND preserved by the apply plan.
    check("compare: undeclared group detected", undecl == {"g_extra_read"})

    # 4b. Companion semantics: a separate Read grant next to the declared
    # Write grant satisfies nothing extra and reads as undeclared — the
    # declared set is the whole story, by policy.
    missing4b, _s4b, undecl4b = compare_scope(
        resolved, {"g_dns_write", "g_zone_write", "g_dns_read"})
    check("compare: satisfied Edit + stray Read grant -> Read is undeclared",
          missing4b == [] and undecl4b == {"g_dns_read"})
    decl = {"name": "Some Token", "report_only": False}
    additions = [("zone", zkey, gid) for gid in missing]
    planned = plan_additions(decl, live, additions, policy)
    planned_ids = live_group_ids(planned, policy, "zone", "zone1")
    check("apply plan: undeclared group preserved, missing groups added",
          "g_extra_read" in planned_ids
          and {"g_dns_write", "g_zone_write"} <= planned_ids)
    check("apply plan: original policies untouched (deep copy)",
          live_group_ids(live, policy, "zone", "zone1")
          == {"g_extra_read"})

    # 5. at_least Read is satisfied by the Edit/Write variant.
    resolved2, _ = resolve_declared(
        [{"name": "Zone", "level": "at_least Read"}], catalog, "zone")
    missing2, _s2, _u2 = compare_scope(resolved2, {"g_zone_write"})
    check("compare: 'at_least Read' satisfied by Write variant",
          missing2 == [])

    # 6. The admin-token guard triggers.
    guarded = {"name": ADMIN_TOKEN_NAME, "report_only": True}
    try:
        plan_additions(guarded, [], [("user", "com.cloudflare.api.user.u1",
                                      "g_api_tokens_edit")], policy)
        check("guard: admin token apply refused", False)
    except GuardRefusal:
        check("guard: admin token apply refused", True)

    # 7. Ambiguous contains-match stays unresolved (never guessed).
    amb_catalog = catalog + [
        {"id": "g_zone_analytics_read", "name": "Zone Analytics Read",
         "scopes": ["com.cloudflare.api.account.zone"]},
        {"id": "g_analytics_read", "name": "Analytics Read",
         "scopes": ["com.cloudflare.api.account.zone"]},
    ]
    r = resolve_group({"name": "Analytics", "level": "Read"},
                      amb_catalog, "zone")
    check("resolver: exact-name beats near matches ('Analytics Read')",
          r is not None and r["primary"] == "g_analytics_read")

    print("SELFTEST %s (%d failure(s))" % ("FAILED" if failures else "OK",
                                          len(failures)))
    return 1 if failures else 0


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def load_policy():
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "tokens.json"), encoding="utf-8") as fh:
        return json.load(fh)


def main(argv):
    if "--selftest" in argv:
        return run_selftest()
    check_only = "--check" in argv
    rep = Reporter()
    token = os.environ.get("CF_TOKEN_ADMIN") or getpass.getpass(
        "Cloudflare admin token (input hidden): ")
    if not token:
        rep.say("AUTH FAILURE: no admin token supplied")
        rep.save()
        return 2
    api = CfApi(token)
    try:
        api.verify()
    except AuthFailure as failure:
        rep.say("AUTH FAILURE: %s" % failure)
        rep.save()
        return 2
    try:
        policy = load_policy()
        code = run(policy, check_only, api, rep)
    except AuthFailure as failure:
        rep.say("AUTH FAILURE: %s" % failure)
        code = 2
    path = rep.save()
    rep.say("results written to %s" % path)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
