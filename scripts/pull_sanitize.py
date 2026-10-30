#!/usr/bin/env python3
"""Run the sanitization gate across the fleet's public/demo
surfaces and regenerate the ONE derived overlay the section
generator consumes: publish-registry/sanitize-overlay.json.

Andrew's rule (Oct 29, 2026): public and demo surfaces must be
PUBLIC AND GENERIC; content that fails the gate falls back to
OWNER-ONLY — visibly. The overlay is how a gate result reaches the
private section's build: for each project whose manifest posture
is `public` (its content ships on public/demo surfaces), this tool
pulls the repo tree, runs fleet-kit's checker
(scripts/check_sanitize.py — the same checker the repos' own
sanitize-gate CI runs, with the repo's own sanitize-exceptions.json)
and records pass/fail with the quoted unexcepted matches. A failing
repo is recorded with the tag "Sanitizer needed": the section
generator keeps that repo's cards in the OWNER dataset carrying
the tag, and drops them from the family dataset entirely — the
fallback is owner-only, never family, and never silent.

Out of scope by posture: `demo-only` and `private` projects (their
content is not a public/demo surface; the demo of a demo-only
project is its own project with its own manifest and is gated as
itself). Live family apps with live data are a separate track.

The overlay is GENERATED, like private-hosts.json: it records each
repo's manifest blob SHA and head SHA so a consumer can tell a
fresh result from a stale one, and it is regenerated in the same
pass as any gate-relevant change (same-push rule).

Usage (from a fleet-kit checkout):
    FLEET_PULL_TOKEN=<token> python3 scripts/pull_sanitize.py [--write]

Without --write it only pulls, scans, and reports. The token needs
contents:read on the fleet repos (two manifests are private);
in-scope trees are public repos and are pulled unauthenticated.
Stdlib only, apart from the checker it imports.
"""

import base64
import io
import json
import os
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_sanitize as cs

API = "https://api.github.com"
OWNER_ACCOUNT = "andrewdhorowitz"
CODELOAD = "https://codeload.github.com"
FLEET_REPOS = [
    "andrewdhorowitz.github.io",
    "routines-and-streaks",
    "aimf-protocol",
    "family-cards-demo",
    "family-cards",
    "fleet-kit",
    "repo-template",
]
ROOT = Path(__file__).resolve().parent.parent
OVERLAY_PATH = ROOT / "publish-registry" / "sanitize-overlay.json"
TERMS_PATH = Path(__file__).resolve().parent / "sanitize_terms.json"
TAG = "Sanitizer needed"
MAX_MATCHES = 25


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


def fetch_bytes(url):
    """Raw bytes (a repo tarball from codeload; public repos only)."""
    req = urllib.request.Request(url, headers={"User-Agent": "pull_sanitize"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read()


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
    return manifest, meta, doc["sha"]


def pull_tree(repo_slug, meta, dest):
    """Extract the repo's default-branch tree into dest."""
    if meta.get("private"):
        raise SystemExit(
            f"{repo_slug}: manifest posture is public but the repo is "
            "private — its tree cannot be pulled unauthenticated, and a "
            "public surface in a private repo needs an owner decision."
        )
    branch = meta.get("default_branch") or "main"
    raw = fetch_bytes(f"{CODELOAD}/{OWNER_ACCOUNT}/{repo_slug}/tar.gz/refs/heads/{branch}")
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tar:
        for member in tar.getmembers():
            parts = Path(member.name).parts
            if len(parts) < 2:
                continue
            member.name = str(Path(*parts[1:]))
            tar.extract(member, dest, filter="data")
    status, commit = fetch_json(
        f"{API}/repos/{OWNER_ACCOUNT}/{repo_slug}/commits/{branch}", None
    )
    return commit["sha"] if status == 200 and commit else None


def scan_tree(root, terms):
    exceptions = cs.load_exceptions(root)
    hits = []
    for p, rel in cs.iter_files(root):
        try:
            data = p.read_bytes()
            if b"\x00" in data[:4096]:
                continue
            text = data.decode("utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for line_no, line in enumerate(text.splitlines(), 1):
            hits.extend(cs.scan_line(line, rel, line_no, terms))
    cs.apply_exceptions(hits, exceptions)
    unexcepted = [h for h in hits if not h.exception_reason]
    excepted = [h for h in hits if h.exception_reason]
    return unexcepted, excepted


def main():
    write = "--write" in sys.argv[1:]
    token = os.environ.get("FLEET_PULL_TOKEN") or os.environ.get("GITHUB_TOKEN")
    terms = cs.Terms(json.loads(TERMS_PATH.read_text()))

    entries = {}
    sources = {}
    print(f"{'repo':28} {'posture':9} gate")
    for repo_slug in FLEET_REPOS:
        manifest, meta, sha = pull_manifest(repo_slug, token)
        sources[repo_slug] = sha
        posture = manifest["status"]
        if posture != "public":
            entries[repo_slug] = {
                "project": manifest["project"],
                "in_scope": False,
                "posture": posture,
            }
            print(f"{repo_slug:28} {posture:9} — (not a public/demo surface)")
            continue
        with tempfile.TemporaryDirectory() as tmp:
            head_sha = pull_tree(repo_slug, meta, Path(tmp))
            unexcepted, excepted = scan_tree(Path(tmp), terms)
        entry = {
            "project": manifest["project"],
            "in_scope": True,
            "manifest_sha": sha,
            "head_sha": head_sha,
            "excepted": len(excepted),
        }
        if unexcepted:
            entry["status"] = "fail"
            entry["tag"] = TAG
            entry["matches"] = [
                {"file": h.path, "line": h.line_no, "label": h.label, "quote": h.quote}
                for h in unexcepted[:MAX_MATCHES]
            ]
            if len(unexcepted) > MAX_MATCHES:
                entry["matches_truncated"] = len(unexcepted) - MAX_MATCHES
            print(f"{repo_slug:28} {posture:9} FAIL — {len(unexcepted)} unexcepted hit(s)")
            for h in unexcepted:
                print("    HIT  " + h.render())
        else:
            entry["status"] = "pass"
            print(
                f"{repo_slug:28} {posture:9} pass "
                f"({len(excepted)} excepted topic hit(s))"
            )
        entries[repo_slug] = entry

    if write:
        overlay = {
            "generated": True,
            "note": (
                "GENERATED by fleet-kit/scripts/pull_sanitize.py — do not "
                "edit by hand. Per-repo sanitization-gate results for the "
                "fleet's public/demo surfaces (posture `public`), consumed "
                "by the private section's generator: a repo recorded as "
                "fail keeps its cards in the OWNER dataset tagged "
                "'Sanitizer needed' and is dropped from the family "
                "dataset. Regenerate in the same pass as any gate-relevant "
                "change; manifest SHAs are recorded so staleness is "
                "checkable."
            ),
            "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "sources": sources,
            "entries": entries,
        }
        OVERLAY_PATH.write_text(json.dumps(overlay, indent=2, sort_keys=True) + "\n")
        failing = [r for r, e in entries.items() if e.get("status") == "fail"]
        print(
            f"wrote {OVERLAY_PATH.relative_to(ROOT)}: "
            f"{len(entries)} repos, failing: {failing or 'none'}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
