#!/usr/bin/env python3
"""Checks for the derived property view (scripts/publish_view.py)
and its wiring in the pull tool (scripts/pull_publish.py).

Covers, against the fleet schema (publish-registry/publish.schema.json):

- the derivation for all seven real manifests (fixtures below mirror
  each live manifest's derivation-relevant fields as of Oct 30,
  2026; the blurbs of the two private repos are placeholders —
  derivation never reads prose, and private-repo text does not get
  copied into this public repo);
- `release_state` carried through the view as display data only:
  it never changes Publish/Tier/Family/Sanitized, a manifest
  without one derives ReleaseState=None, and a value outside the
  enum (including the dropped "demo") fails validation;
- the Family rule: family_visible with status "public" fails
  validation with the rule named, and derive() refuses it; with a
  private posture it validates and derives Tier=Private;
- the Sanitized hard rule: Sanitized=False is never public-facing —
  and neither is an unknown (None) result;
- unknown keys (a `properties` block, a hand-set `sanitized`, a
  stray `force_publish`): reported as drift, inert for validation,
  and never read by the derivation — a hand-set `sanitized` key
  cannot manufacture Sanitized=True or override the overlay;
- the pre-existing Shared Infrastructure rule still enforced;
- freshness badges (design approved Oct 30, 2026): derived by
  publish_view.freshness() from the manifest timestamps
  `first_released` / `last_released` against a fixed build date —
  release_state labels win, then "New" (30 days from first release,
  released projects only), then "Recently updated" (14 days from
  last release); no timestamps derives no badge, a hand-set badge
  is inert unknown-key drift, and freshness never feeds the five
  properties;
- declared_mode() in the pull tool agreeing with the view for all
  seven repos (the mode projection did not change meaning).

Exits 0 only if every check behaves. Run:
    python3 scripts/test_publish_view.py
Needs the jsonschema package, like pull_publish.py itself.
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import publish_view as pv
import pull_publish as pp

SCHEMA = pv.load_schema()
SHA = "f" * 40  # fixture manifest SHA for overlay-freshness checks

FAILURES = []


def check(cond, msg):
    if cond:
        print("  ok — " + msg)
    else:
        FAILURES.append(msg)
        print("  FAIL — " + msg)


def manifest(
    project,
    status,
    group,
    family_visible,
    also=None,
    release_state=None,
    first_released=None,
    last_released=None,
):
    section = {
        "include": True,
        "group": group,
        "blurb": f"{project} fixture blurb.",
        "family_visible": family_visible,
    }
    if also is not None:
        section["also"] = also
    m = {
        "project": project,
        "status": status,
        "public_urls": {"site": None, "demo": None, "docs": None, "interactive": None},
        "private_hosts": [],
        "section": section,
    }
    if release_state is not None:
        m["release_state"] = release_state
    if first_released is not None:
        m["first_released"] = first_released
    if last_released is not None:
        m["last_released"] = last_released
    return m


# The seven real manifests, derivation-relevant fields (Oct 30, 2026).
REAL = {
    "andrewdhorowitz.github.io": (
        manifest("andrewdhorowitz.com", "public", "projects", False),
        {
            "Publish": True,
            "Tier": "Public",
            "Shelf": "projects",
            "Family": False,
            "ReleaseState": None,
        },
        "public",
    ),
    "routines-and-streaks": (
        manifest(
            "Routines & Streaks", "public", "projects", False, release_state="testing"
        ),
        {
            "Publish": True,
            "Tier": "Public",
            "Shelf": "projects",
            "Family": False,
            "ReleaseState": "testing",
        },
        "public",
    ),
    "aimf-protocol": (
        manifest("AIMF", "public", "projects", False),
        {
            "Publish": True,
            "Tier": "Public",
            "Shelf": "projects",
            "Family": False,
            "ReleaseState": None,
        },
        "public",
    ),
    "family-cards-demo": (
        manifest("Family Cards Demo", "public", "projects", False),
        {
            "Publish": True,
            "Tier": "Public",
            "Shelf": "projects",
            "Family": False,
            "ReleaseState": None,
        },
        "public",
    ),
    "family-cards": (
        manifest("Family Cards", "private", "family", True, release_state="testing"),
        {
            "Publish": True,
            "Tier": "Private",
            "Shelf": "family",
            "Family": True,
            "ReleaseState": "testing",
        },
        "private",
    ),
    "fleet-kit": (
        manifest("Fleet Kit", "public", "shared-infrastructure", False),
        {
            "Publish": True,
            "Tier": "Public",
            "Shelf": "shared-infrastructure",
            "Family": False,
            "ReleaseState": None,
        },
        "public",
    ),
    "repo-template": (
        manifest("Repo Template", "private", "shared-infrastructure", False),
        {
            "Publish": True,
            "Tier": "Private",
            "Shelf": "shared-infrastructure",
            "Family": False,
            "ReleaseState": None,
        },
        "private",
    ),
}
IN_SCOPE = [r for r, (m, _v, _mode) in REAL.items() if m["status"] == "public"]


def overlay_with(entries):
    return {"generated": True, "entries": entries}


def fresh_entry(status="pass", sha=SHA):
    return {"in_scope": True, "manifest_sha": sha, "status": status}


print("== the seven real manifests ==")
for repo, (m, expected, mode) in REAL.items():
    check(pv.validate(m, SCHEMA) == [], f"{repo}: validates against the schema")
    check(pv.find_unknown_keys(m, SCHEMA) == [], f"{repo}: no unknown keys")
    entry = fresh_entry() if repo in IN_SCOPE else {"in_scope": False}
    view, warnings = pv.derive(m, entry, SHA)
    for key, want in expected.items():
        check(view[key] == want, f"{repo}: {key} == {want!r} (got {view[key]!r})")
    want_sanitized = True if repo in IN_SCOPE else None
    check(
        view["Sanitized"] == want_sanitized,
        f"{repo}: Sanitized == {want_sanitized!r} (got {view['Sanitized']!r})",
    )
    check(warnings == [], f"{repo}: no derivation warnings")
    check(
        pp.declared_mode(m) == mode,
        f"{repo}: declared_mode == {mode!r} (got {pp.declared_mode(m)!r})",
    )

print("== Tier derivation ==")
view, _ = pv.derive(manifest("Plain Private", "private", "projects", False))
check(view["Tier"] == "Private", "private derives to Tier=Private")
view, _ = pv.derive(None)
check(
    view
    == {
        "Publish": False,
        "Tier": None,
        "Shelf": None,
        "Family": False,
        "Sanitized": None,
        "ReleaseState": None,
        "Freshness": None,
    },
    "no marker at all derives Publish=False and nothing else",
)
bare = manifest("No Section", "public", "projects", False)
del bare["section"]
view, _ = pv.derive(bare)
check(
    view["Shelf"] is None and view["Family"] is False,
    "a manifest with no section derives Shelf=None, Family=False",
)

print("== Family rule (Family=True forces Tier=Private) ==")
bad = manifest("Bad Combo", "public", "family", True)
errors = pv.validate(bad, SCHEMA)
check(
    bool(errors) and errors[0].startswith("Family rule:"),
    f"family_visible + status public fails validation, rule named (got {errors})",
)
try:
    pv.derive(bad)
    check(False, "derive() refuses family_visible + status public")
except ValueError as e:
    check("Family rule" in str(e), "derive() refuses family_visible + status public")
for posture in ("private",):
    ok = manifest("Good Combo", posture, "family", True)
    check(
        pv.validate(ok, SCHEMA) == [],
        f"family_visible + status {posture} validates",
    )
    view, _ = pv.derive(ok)
    check(
        view["Family"] is True and view["Tier"] == "Private",
        f"family_visible + status {posture} derives Family=True, Tier=Private",
    )

print("== release_state: display data only ==")
base = manifest("Lifecycle", "public", "projects", False)
variants = [base] + [
    manifest("Lifecycle", "public", "projects", False, release_state=state)
    for state in ("under_construction", "testing", "released")
]
views = [pv.derive(v, fresh_entry("pass"), SHA)[0] for v in variants]
check(
    views[0]["ReleaseState"] is None,
    "a marker without release_state derives ReleaseState=None",
)
for state, view in zip(("under_construction", "testing", "released"), views[1:]):
    check(
        view["ReleaseState"] == state,
        f"release_state {state!r} is carried through verbatim",
    )
core = [
    {k: v[k] for k in ("Publish", "Tier", "Family", "Sanitized")} for v in views
]
check(
    all(c == core[0] for c in core),
    "release_state never changes Publish/Tier/Family/Sanitized (independence)",
)
check(
    pv.validate(variants[2], SCHEMA) == [],
    "a manifest with a valid release_state validates",
)
gone = manifest("Gone Value", "public", "projects", False, release_state="demo")
check(
    pv.validate(gone, SCHEMA) != [],
    "release_state 'demo' fails validation (value dropped Oct 30, 2026)",
)
check(
    pv.find_unknown_keys(variants[1], SCHEMA) == [],
    "release_state is a declared key, not drift",
)

print("== Sanitized hard rule ==")
public_m = manifest("Public Thing", "public", "projects", False)
view, _ = pv.derive(public_m, fresh_entry("pass"), SHA)
check(
    view["Sanitized"] is True and pv.public_facing(view),
    "Tier=Public + Sanitized=True is public-facing",
)
view, _ = pv.derive(public_m, fresh_entry("fail"), SHA)
check(view["Sanitized"] is False, "fresh gate failure derives Sanitized=False")
check(
    not pv.public_facing(view),
    "Sanitized=False is NEVER public-facing",
)
view, warnings = pv.derive(public_m, fresh_entry("pass", sha="0" * 40), SHA)
check(
    view["Sanitized"] is None and warnings and "stale" in warnings[0],
    "stale overlay entry is ignored with a warning (Sanitized=None)",
)
check(
    not pv.public_facing(view),
    "an unknown Sanitized result is not public-facing either",
)
view, _ = pv.derive(public_m, {"in_scope": False}, SHA)
check(view["Sanitized"] is None, "out-of-scope posture has no gate result")
view, _ = pv.derive(manifest("Priv", "private", "projects", False), fresh_entry(), SHA)
check(
    view["Sanitized"] is True and not pv.public_facing(view),
    "Tier=Private is not public-facing even when Sanitized=True",
)

print("== unknown keys: drift, inert, never read ==")
weird = manifest(
    "Weird Keys",
    "public",
    "projects",
    False,
    also=[
        {"name": "Companion", "blurb": "c", "link": "https://example.com/", "tier": "x"}
    ],
)
weird["properties"] = {"tier": "public", "family": False}
weird["sanitized"] = False
weird["force_publish"] = True
weird["public_urls"]["repo"] = "https://example.com/repo"
weird["section"]["tier"] = "public"
drift = pv.find_unknown_keys(weird, SCHEMA)
expected_drift = {
    "properties",
    "sanitized",
    "force_publish",
    "public_urls.repo",
    "section.tier",
    "section.also[0].tier",
}
check(
    set(drift) == expected_drift,
    f"all unknown keys reported as drift (got {drift})",
)
check(
    pv.validate(weird, SCHEMA) == [],
    "unknown keys do not fail validation (inert, not fatal)",
)
cleaned = pv.strip_unknown_keys(weird, SCHEMA)
check(
    pv.find_unknown_keys(cleaned, SCHEMA) == [] and "properties" in weird,
    "strip_unknown_keys cleans a copy and leaves the original intact",
)
view, _ = pv.derive(weird)
check(
    view["Sanitized"] is None,
    "a hand-set `sanitized` key is never read: no overlay, no Sanitized value",
)
view, _ = pv.derive(weird, fresh_entry("pass"), SHA)
check(
    view["Sanitized"] is True,
    "the overlay decides Sanitized even when a hand-set key says otherwise",
)


print("== Freshness badges: derived, precedence, windows ==")
BUILD = "2026-10-30"  # fixed build/pull date for every check below

def fresh(**kw):
    return pv.freshness(manifest("Fresh", "public", "projects", False, **kw), BUILD)

check(
    fresh(release_state="released", first_released="2026-10-10", last_released="2026-10-10")
    == "New",
    "released 20 days ago -> New",
)
check(
    fresh(release_state="released", first_released="2026-09-30") == "New",
    "first release exactly 30 days before the build date -> New (window inclusive)",
)
check(
    fresh(release_state="released", first_released="2026-09-29", last_released="2026-10-25")
    == "Recently updated",
    "first release 31 days ago (New expired) + last release 5 days ago -> Recently updated",
)
check(
    fresh(release_state="released", first_released="2026-01-01", last_released="2026-10-16")
    == "Recently updated",
    "last release exactly 14 days before the build date -> Recently updated (window inclusive)",
)
check(
    fresh(release_state="released", first_released="2026-01-01", last_released="2026-10-15")
    is None,
    "last release 15 days ago -> no badge (window expired on its own)",
)
check(
    fresh(release_state="testing", first_released="2026-10-29", last_released="2026-10-29")
    == "testing",
    "precedence: release_state 'testing' wins over a would-be New badge",
)
check(
    fresh(release_state="under_construction", last_released="2026-10-29")
    == "under_construction",
    "precedence: release_state 'under_construction' wins over a would-be Recently updated",
)
check(
    fresh(first_released="2026-10-29", last_released="2026-01-01") is None,
    "'New' applies only to released projects: no release_state, fresh first_released -> no New",
)
check(
    fresh(first_released="2026-01-01", last_released="2026-10-28") == "Recently updated",
    "no release_state + last release 2 days ago -> Recently updated",
)
check(
    fresh(release_state="released") is None,
    "a manifest with no timestamps derives no badge (the seven real manifests today)",
)
check(
    fresh(release_state="released", first_released="2026-11-05", last_released="2026-11-05")
    is None,
    "timestamps after the build date earn no badge",
)
check(
    fresh(release_state="released", first_released="not-a-date", last_released="2026-10-28")
    == "Recently updated",
    "an unparseable first_released is ignored, not fatal; last_released still derives",
)
timed = manifest(
    "Timed", "public", "projects", False,
    release_state="released", first_released="2026-10-10", last_released="2026-10-10",
)
check(pv.validate(timed, SCHEMA) == [], "a manifest carrying both timestamps validates")
check(
    pv.find_unknown_keys(timed, SCHEMA) == [],
    "first_released / last_released are declared keys, not drift",
)
view, _ = pv.derive(timed, fresh_entry("pass"), SHA, on_date=BUILD)
check(view["Freshness"] == "New", "derive() carries Freshness from the same timestamps")
plain = manifest("Timed", "public", "projects", False, release_state="released")
view_plain, _ = pv.derive(plain, fresh_entry("pass"), SHA, on_date=BUILD)
core_t = {k: view[k] for k in ("Publish", "Tier", "Shelf", "Family", "Sanitized")}
core_p = {k: view_plain[k] for k in ("Publish", "Tier", "Shelf", "Family", "Sanitized")}
check(
    core_t == core_p and view_plain["Freshness"] is None,
    "timestamps change only Freshness, never the five properties",
)
handset = manifest("Handset", "public", "projects", False, release_state="released")
handset["freshness"] = "New"
check(
    "freshness" in pv.find_unknown_keys(handset, SCHEMA),
    "a hand-set `freshness` key is unknown-key drift",
)
view, _ = pv.derive(handset, on_date=BUILD)
check(
    view["Freshness"] is None,
    "a hand-set `freshness` key is never read: badges are derived, never hand-set",
)

print("== standing rules still enforced ==")
si = manifest("SI Family", "private", "shared-infrastructure", True)
errors = pv.validate(si, SCHEMA)
check(
    bool(errors) and not errors[0].startswith("Family rule:"),
    f"Shared Infrastructure + family_visible still fails (got {errors})",
)
bad_status = manifest("Bad Status", "weird", "projects", False)
check(pv.validate(bad_status, SCHEMA) != [], "an unknown status fails validation")
old_status = manifest("Old Status", "demo-only", "projects", False)
check(
    pv.validate(old_status, SCHEMA) != [],
    "status 'demo-only' fails validation (value removed Oct 30, 2026)",
)

print()
if FAILURES:
    print(f"{len(FAILURES)} check(s) FAILED")
    sys.exit(1)
print("all checks passed")
