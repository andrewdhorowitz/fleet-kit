#!/usr/bin/env python3
"""Pull every fleet project's publish.json from its own repo, validate
it against the fleet schema, and regenerate the ONE derived artifact
the fleet keeps: publish-registry/private-hosts.json, the portfolio
gate's denylist input.

One project = one repo (Andrew's rule, Oct 29, 2026): a project's
publish.json lives only in that project's repo, and every consumer
pulls it from there. This tool is shared infrastructure (fleet-kit) —
it is the sanctioned way to read the whole fleet's publish intent.
It stores NO manifest copies: the index it writes contains only the
declared-private host strings (which are not secret — the gate they
feed runs in the public portfolio's CI, where private repos cannot
be read), each with the project and source repo it came from, plus
the source manifest blob SHAs so staleness is checkable at a glance.

It also checks Andrew's visibility-follows-mode rule (Oct 29, 2026):
a repo's actual GitHub visibility must match the mode its manifest
declares — public mode means a public repo; a private-tier mode
(family/owner) means a private repo — and the two fleet repos that
carry no manifest (private-section, fleet-ci) have their modes
declared by role below. Mismatches are REPORTED, one line each,
never fixed here: flipping toward public is an exposure that needs
Andrew's explicit word per repo, and flipping a Pages-hosted repo
toward private can take its site offline.

Usage (from a fleet-kit checkout):
    FLEET_PULL_TOKEN=<token> python3 scripts/pull_publish.py [--write]

Without --write it only pulls, validates, and reports. The token
needs contents:read on the fleet repos (family-cards and
repo-template are private); public repos pull unauthenticated.
Requires the `jsonschema` package for validation.
"""

import base64
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

API = "https://api.github.com"
OWNER_ACCOUNT = "andrewdhorowitz"
# Fleet membership: shared-infrastructure knowledge, kept here in the
# kit layer — never in a project repo.
FLEET_REPOS = [
    "andrewdhorowitz.github.io",
    "routines-and-streaks",
    "aimf-protocol",
    "family-cards-demo",
    "family-cards",
    "fleet-kit",
    "repo-template",
]
# Fleet repos with no publish.json: their modes are declared by role
# in the spec (PUBLISH-MANIFEST-SPEC) — private-section is the private
# consumer/display (it holds the tier logic and the fleet's secrets),
# fleet-ci is the public host for the shared reusable workflow
# (public callers can only call public reusable workflows).
ROLE_MODE_REPOS = {
    "private-section": "private",
    "fleet-ci": "public",
}
ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / "publish-registry" / "publish.schema.json"
INDEX_PATH = ROOT / "publish-registry" / "private-hosts.json"


def fetch_json(url, token):
    """(status, parsed body or None). Factored so local drivers can
    substitute an authenticated transport."""
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            **({"Authorization": f"Bearer {token}"} if token else {}),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, None


def pull_manifest(repo_slug, token):
    status, meta = fetch_json(f"{API}/repos/{OWNER_ACCOUNT}/{repo_slug}", token)
    if status != 200 or not meta:
        raise SystemExit(
            f"pull failed for {repo_slug}: repo metadata HTTP {status} "
            "(private repos need FLEET_PULL_TOKEN with contents:read)"
        )
    status, doc = fetch_json(
        f"{API}/repos/{OWNER_ACCOUNT}/{repo_slug}/contents/publish.json", token
    )
    if status != 200 or not doc or not doc.get("content"):
        raise SystemExit(f"pull failed for {repo_slug}: publish.json HTTP {status}")
    manifest = json.loads(base64.b64decode(doc["content"]))
    return manifest, bool(meta.get("private")), doc["sha"]


def repo_is_private(repo_slug, token):
    status, meta = fetch_json(f"{API}/repos/{OWNER_ACCOUNT}/{repo_slug}", token)
    if status != 200 or not meta:
        raise SystemExit(
            f"visibility check failed for {repo_slug}: repo metadata HTTP {status} "
            "(private repos need FLEET_PULL_TOKEN with contents:read)"
        )
    return bool(meta.get("private"))


def declared_mode(manifest):
    """The repo visibility a manifest's declared mode prescribes.

    status "public" -> public repo. Status "private" -> private repo.
    Status "demo-only" -> private repo: the repo itself holds the
    private live surface; any public demo is a separate project in
    its OWN repo, never a reason for this repo to be public. A
    private-tier section entry (family group or family_visible) also
    prescribes a private repo, whatever the status says.
    """
    section = manifest.get("section") or {}
    if section.get("family_visible") or section.get("group") == "family":
        return "private"
    return "public" if manifest.get("status") == "public" else "private"


def main():
    write = "--write" in sys.argv[1:]
    try:
        import jsonschema
    except ImportError:
        raise SystemExit("pull_publish.py needs the jsonschema package to validate")
    schema = json.loads(SCHEMA_PATH.read_text())
    token = os.environ.get("FLEET_PULL_TOKEN") or os.environ.get("GITHUB_TOKEN")

    hosts = []
    sources = {}
    mismatches = []
    print(f"{'repo':28} {'project':22} {'status':9} {'mode':8} {'actual':8} hosts")
    for repo_slug in FLEET_REPOS:
        manifest, repo_private, sha = pull_manifest(repo_slug, token)
        jsonschema.validate(manifest, schema)
        sources[repo_slug] = sha
        declared = manifest.get("private_hosts") or []
        for raw in declared:
            hosts.append(
                {"host": raw, "project": manifest["project"], "repo": repo_slug}
            )
        mode = declared_mode(manifest)
        actual = "private" if repo_private else "public"
        if mode != actual:
            mismatches.append((repo_slug, mode, actual, "manifest"))
        print(
            f"{repo_slug:28} {manifest['project']:22} {manifest['status']:9} "
            f"{mode:8} {actual:8} {len(declared)}"
        )
    print(f"all {len(FLEET_REPOS)} manifests pulled and schema-valid")

    for repo_slug, mode in ROLE_MODE_REPOS.items():
        actual = "private" if repo_is_private(repo_slug, token) else "public"
        if mode != actual:
            mismatches.append((repo_slug, mode, actual, "role"))
        print(f"{repo_slug:28} {'(no manifest)':22} {'-':9} {mode:8} {actual:8} -")

    if mismatches:
        for repo_slug, mode, actual, basis in mismatches:
            print(
                f"VISIBILITY MISMATCH: {repo_slug} — declared mode {mode} "
                f"(by {basis}) but repo is {actual}"
            )
    else:
        total = len(FLEET_REPOS) + len(ROLE_MODE_REPOS)
        print(f"visibility: all {total} repos match their declared mode")

    if write:
        index = {
            "generated": True,
            "note": (
                "GENERATED by fleet-kit/scripts/pull_publish.py from each "
                "repo's own publish.json — do not edit by hand. Contains "
                "only declared-private host strings for the portfolio "
                "publish gate; the manifests themselves live in their "
                "own repos and are pulled from there."
            ),
            "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "sources": sources,
            "private_hosts": hosts,
        }
        INDEX_PATH.write_text(json.dumps(index, indent=2, sort_keys=True) + "\n")
        print(f"wrote {INDEX_PATH.relative_to(ROOT)}: {len(hosts)} private host(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
