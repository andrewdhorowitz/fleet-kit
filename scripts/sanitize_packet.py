#!/usr/bin/env python3
"""Sanitize pass — the remediation mechanism on top of the gate.

The gate (scripts/check_sanitize.py) DETECTS: a public/demo repo
whose content is not public-and-generic fails, keeps its section
cards owner-only under a generated "Sanitizer needed" tag, and
drops out of the family dataset. This tool is the FIX path Andrew
approved (Oct 29, 2026): tag -> work packet -> dispositions ->
branch + PR -> re-gate. Merging stays Andrew's word; nothing here
merges, and nothing here edits a default branch.

Flow:

  1. build — scan a repo FRESH (pulled tree, or a local checkout)
     and emit a packet: publish-registry/packets/<repo>.json in
     fleet-kit. One entry per unexcepted hit, each with an empty
     `disposition` slot to fill:
       generalize — rewrite the matched wording to a general form.
                    The packet carries `anchor` (the exact matched
                    text) and a `draft` slot for the replacement.
       substitute — swap an identifier for an invented replacement
                    from the repo's sanitize-substitutions.json
                    (hash -> invented string; see below). The pass
                    never invents replacements for real data: it
                    applies table entries only.
       relocate   — git-mv the whole file into the repo's relocate
                    dir (packet field `relocate_dir`, default
                    private-staging/), optionally leaving a generic
                    stub at the original path (packet `stub` text).
       except     — record a reasoned exception in the repo's
                    sanitize-exceptions.json. Topic class only,
                    reason mandatory — the checker's own validation.
  2. apply — execute a filled packet against a local checkout ON A
     BRANCH (sanitize-pass/<date>): validate EVERYTHING first (any
     anchor mismatch, missing table entry, or invalid disposition
     fails the whole apply before a single file is touched — no
     fuzzy edits, ever), then edit, commit, and RE-GATE: the branch
     tree is scanned again and the packet closes only when the scan
     is clean-or-excepted. Apply is idempotent: re-running reports
     already-applied per hit instead of duplicating work.
  3. --push / --pr — push the branch and open a PR whose body is
     the packet summary. The body states the closure rule: merging
     does NOT itself clear the "Sanitizer needed" tag — the tag is
     build-generated from the overlay and clears when the overlay
     is regenerated after merge (pull_sanitize.py --write) and
     shows the repo passing.

Packet privacy (load-bearing): fleet-kit is PUBLIC, and a packet
quotes its evidence — so identifier hits are recorded as SHA-256
digests + file/line ONLY. Never the value, never quoted context:
a packet for a real failing repo must not itself publish the
identifiers it exists to remove (the same reasoning that hashes
the checker's term file). Topic hits carry the term and a quoted
window — topic vocabulary is general category language, and the
quotes are what make a generalization draft reviewable.

Substitution tables — sanitize-substitutions.json, at the TARGET
repo's root, owner-maintained:
    {
      "version": 1,
      "substitutions": [
        {"identifier_hash": "<64 hex sha256, as in the packet>",
         "replacement": "<invented string>",
         "note": "<optional>"}
      ]
    }
The hash is the packet's `term_hash` (the checker's digest of the
identifier's normalized form). A replacement must itself scan
clean under the checker (an invented address on a reserved domain,
an invented name that is not a family identifier). Precedent: the
Family Cards demo was built from the live app by exactly this
move — real kid data swapped for invented Emma/Noah data — done by
hand; the table makes that one-off a reusable mechanism.

Relocation staging: the checker skips directories named
private-staging (a named carve-out in check_sanitize.py), so a
relocated file leaves the scanned surface. Staged content in a
public repo is still in a public repo — off-surface, NOT secret —
and the follow-up (move behind the gate, or delete) stays an
owner decision the PR body names.

Usage:
    sanitize_packet.py build --repo <slug> [--out <packet.json>]
    sanitize_packet.py build --repo-dir <dir> --repo-name <label>
    sanitize_packet.py show --packet <packet.json>
    sanitize_packet.py apply --packet <packet.json> --repo-dir <dir>
                             [--branch <name>] [--push] [--pr]
                             [--repo-slug <owner/name>]

Stdlib only, like the rest of the gate family.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_sanitize as cs
import pull_sanitize as ps

PACKET_VERSION = 1
DISPOSITIONS = ("generalize", "substitute", "relocate", "except")
DEFAULT_RELOCATE_DIR = "private-staging/"
STAGING_DIRNAME = "private-staging"
SUBSTITUTIONS_NAME = "sanitize-substitutions.json"
HEX64 = re.compile(r"^[0-9a-f]{64}$")
KIT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OVERLAY = KIT_ROOT / "publish-registry" / "sanitize-overlay.json"
DEFAULT_PACKETS_DIR = KIT_ROOT / "publish-registry" / "packets"
API = "https://api.github.com"


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def today():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def load_terms():
    return cs.Terms(json.loads((Path(__file__).resolve().parent / "sanitize_terms.json").read_text()))


def digest_for_hit(hit):
    """The terms-file digest of a hit's identifier (cs.hash_term is
    the same normalization the checker used to match it)."""
    return cs.hash_term(hit.term)


# ----------------------------------------------------------------
# Substitution tables

def validate_substitutions(doc, terms, where):
    """Return {identifier_hash: replacement}; raise SystemExit on
    any schema or cleanliness violation."""
    if not isinstance(doc, dict) or doc.get("version") != 1:
        raise SystemExit(f"{where}: sanitize-substitutions.json must be an object with version 1")
    out = {}
    for i, e in enumerate(doc.get("substitutions") or []):
        h, r = e.get("identifier_hash"), e.get("replacement")
        if not h or not HEX64.match(h):
            raise SystemExit(f"{where}: substitutions[{i}] has no valid identifier_hash (64 hex)")
        if not r or not isinstance(r, str):
            raise SystemExit(f"{where}: substitutions[{i}] has no replacement string")
        if h in out:
            raise SystemExit(f"{where}: duplicate substitution for hash {h[:12]}…")
        hits = cs.scan_line(r, "<replacement>", 1, terms)
        if hits:
            raise SystemExit(
                f"{where}: replacement for hash {h[:12]}… is not itself clean "
                f"(hits: {[x.label for x in hits]}) — replacements must scan clean"
            )
        out[h] = r
    return out


def load_substitutions(repo_dir, terms):
    f = Path(repo_dir) / SUBSTITUTIONS_NAME
    if not f.exists():
        return {}
    return validate_substitutions(json.loads(f.read_text()), terms, str(f))


# ----------------------------------------------------------------
# Scanning (span-aware, via the checker's own machinery)

def scan_detailed(root, terms):
    """(unexcepted, excepted) hits with spans, exceptions applied —
    the same scan pull_sanitize performs, kept span-bearing."""
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
    unexcepted.sort(key=lambda h: (h.path, h.line_no, h.start or 0))
    return unexcepted, excepted


def line_text(root, rel, line_no):
    try:
        lines = (Path(root) / rel).read_text().splitlines()
    except (OSError, UnicodeDecodeError):
        return ""
    return lines[line_no - 1] if 0 < line_no <= len(lines) else ""


# ----------------------------------------------------------------
# Packet build

def build_packet(repo_label, root, terms, source):
    unexcepted, excepted = scan_detailed(root, terms)
    table = load_substitutions(root, terms)
    hits = []
    for i, h in enumerate(unexcepted, 1):
        entry = {
            "id": f"h{i}",
            "file": h.path,
            "line": h.line_no,
            "class": h.kind,
            "label": h.label,
            "disposition": None,
            "applied": False,
        }
        if h.kind == "identifier":
            # Digest + location ONLY — never the value, never a quote.
            entry["term_hash"] = digest_for_hit(h)
            entry["replacement"] = table.get(entry["term_hash"])
        else:
            entry["term"] = h.term
            entry["quote"] = h.quote
            line = line_text(root, h.path, h.line_no)
            entry["anchor"] = line[h.start : h.end] if h.start is not None else h.term
            entry["draft"] = None
            entry["reason"] = None
        entry["stub"] = None
        hits.append(entry)
    return {
        "packet_version": PACKET_VERSION,
        "tool": "fleet-kit/scripts/sanitize_packet.py",
        "repo": repo_label,
        "generated_at": now_iso(),
        "source": source,
        "privacy": (
            "Identifier hits are recorded as SHA-256 digests + file/line only — "
            "never the value, never quoted context (fleet-kit is public; a packet "
            "must not publish what it exists to remove). Topic hits carry the "
            "term and a quoted window: topic vocabulary is general."
        ),
        "relocate_dir": DEFAULT_RELOCATE_DIR,
        "status": "open" if hits else "no-hits",
        "excepted_at_build": len(excepted),
        "hits": hits,
        "applied": None,
    }


def overlay_source(repo_slug, head_sha, manifest_sha):
    """Cross-check the committed overlay — the packet works from a
    FRESH scan, and says plainly whether the overlay agrees."""
    src = {"mode": "pull", "head_sha": head_sha, "manifest_sha": manifest_sha}
    if DEFAULT_OVERLAY.exists():
        try:
            overlay = json.loads(DEFAULT_OVERLAY.read_text())
            entry = (overlay.get("entries") or {}).get(repo_slug) or {}
            src["overlay_status"] = entry.get("status", "unknown")
            src["overlay_head_sha"] = entry.get("head_sha")
            src["overlay_fresh"] = bool(
                entry.get("head_sha") and entry.get("head_sha") == head_sha
            )
        except (OSError, json.JSONDecodeError):
            src["overlay_status"] = "unreadable"
    else:
        src["overlay_status"] = "absent"
    return src


def cmd_build(args):
    terms = load_terms()
    if args.refresh_overlay:
        print("refreshing overlay via pull_sanitize.py --write …")
        r = subprocess.run(
            [sys.executable, str(Path(__file__).resolve().parent / "pull_sanitize.py"), "--write"]
        )
        if r.returncode != 0:
            raise SystemExit("overlay refresh failed — packet not built from a stale base")
    if args.repo:
        token = os.environ.get("FLEET_PULL_TOKEN") or os.environ.get("GITHUB_TOKEN")
        manifest, meta, manifest_sha = ps.pull_manifest(args.repo, token)
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            head_sha = ps.pull_tree(args.repo, meta, Path(tmp))
            source = overlay_source(args.repo, head_sha, manifest_sha)
            packet = build_packet(args.repo, Path(tmp), terms, source)
        label = args.repo
    else:
        root = Path(args.repo_dir)
        if not root.is_dir():
            raise SystemExit(f"--repo-dir {root} is not a directory")
        packet = build_packet(
            args.repo_name, root, terms, {"mode": "local", "dir": str(root)}
        )
        label = args.repo_name
    out = Path(args.out) if args.out else DEFAULT_PACKETS_DIR / f"{label}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(packet, indent=2, sort_keys=True) + "\n")
    print(f"packet: {out}")
    print(f"repo: {label} — {len(packet['hits'])} unexcepted hit(s), "
          f"{packet['excepted_at_build']} already excepted")
    for h in packet["hits"]:
        if h["class"] == "identifier":
            print(f"  {h['id']}  {h['file']}:{h['line']}  [{h['label']}]  "
                  f"hash {h['term_hash'][:12]}… (value not recorded)")
        else:
            print(f"  {h['id']}  {h['file']}:{h['line']}  [{h['label']}]  …{h['quote']}…")
    if packet["hits"]:
        print("fill each hit's disposition (generalize / substitute / relocate / "
              "except), then: apply --packet <this file> --repo-dir <checkout>")
    return 0


def load_packet(path):
    packet = json.loads(Path(path).read_text())
    if packet.get("packet_version") != PACKET_VERSION:
        raise SystemExit(f"{path}: unsupported packet_version {packet.get('packet_version')}")
    return packet


def cmd_show(args):
    packet = load_packet(args.packet)
    print(f"packet for {packet['repo']} — status: {packet['status']}")
    print(f"generated {packet['generated_at']} from {packet['source']}")
    print(f"relocate_dir: {packet['relocate_dir']}")
    for h in packet["hits"]:
        disp = h.get("disposition") or "(unfilled)"
        state = "applied" if h.get("applied") else "pending"
        if h["class"] == "identifier":
            print(f"  {h['id']}  {h['file']}:{h['line']}  [{h['label']}]  "
                  f"hash {h['term_hash'][:12]}…  -> {disp}  [{state}]")
        else:
            print(f"  {h['id']}  {h['file']}:{h['line']}  [{h['label']}]  "
                  f"anchor {h['anchor']!r}  -> {disp}  [{state}]")
    if packet.get("applied"):
        a = packet["applied"]
        print(f"applied {a['at']} on branch {a['branch']} (commit {a['commit'][:12]}…); "
              f"re-gate: {a['regate']}")
    return 0


# ----------------------------------------------------------------
# Validation — the whole apply stands or falls here, before any write

def validate_filled(packet, repo_dir, terms, table):
    """Return a list of human-readable errors ([] = apply may run)."""
    errors = []
    relocate_dir = (packet.get("relocate_dir") or DEFAULT_RELOCATE_DIR).strip("/")
    by_file = {}
    for h in packet["hits"]:
        by_file.setdefault(h["file"], []).append(h)
        disp = h.get("disposition")
        hid = f"{h['id']} ({h['file']}:{h['line']})"
        if disp not in DISPOSITIONS:
            errors.append(f"{hid}: disposition {disp!r} is not one of {DISPOSITIONS}")
            continue
        if disp == "except":
            if h["class"] != "topic":
                errors.append(f"{hid}: except is topic-class only — identifiers are definite hits")
            elif not (h.get("reason") or "").strip():
                errors.append(f"{hid}: except requires a reason")
        elif disp == "substitute":
            if h["class"] != "identifier":
                errors.append(f"{hid}: substitute is for identifier hits (topics generalize)")
            elif not (h.get("replacement") or table.get(h.get("term_hash"))):
                errors.append(
                    f"{hid}: no replacement — fill the hit's replacement slot or add "
                    f"hash {h.get('term_hash', '')[:12]}… to {SUBSTITUTIONS_NAME}"
                )
            else:
                repl = h.get("replacement") or table[h["term_hash"]]
                hits = cs.scan_line(repl, "<replacement>", 1, terms)
                if hits:
                    errors.append(f"{hid}: replacement is not itself clean ({[x.label for x in hits]})")
        elif disp == "generalize":
            if h["class"] != "topic":
                errors.append(f"{hid}: generalize is for topic hits (identifiers substitute)")
            elif not h.get("anchor"):
                errors.append(f"{hid}: generalize needs an anchor")
            elif h.get("draft") is None:
                errors.append(f"{hid}: generalize needs a draft (use \"\" only as a deliberate deletion)")
        elif disp == "relocate":
            pass  # file-level checks below
    for path, hs in by_file.items():
        disps = {h.get("disposition") for h in hs}
        if "relocate" in disps and disps != {"relocate"}:
            errors.append(
                f"{path}: mixed dispositions {sorted(d for d in disps if d)} — a relocated "
                "file's hits all relocate (fix the others first, or relocate alone)"
            )
        src = Path(repo_dir) / path
        dst = Path(repo_dir) / relocate_dir / path
        if "relocate" in disps and not all(h.get("applied") for h in hs):
            if not src.exists() and not dst.exists():
                errors.append(f"{path}: relocate source missing and no staged copy exists")
            if src.exists() and dst.exists():
                errors.append(f"{path}: both the file and its staged copy exist — resolve by hand")
    return errors


# ----------------------------------------------------------------
# Apply

def git(repo_dir, *argv, check=True):
    r = subprocess.run(["git", "-C", str(repo_dir), *argv],
                       capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(f"git {' '.join(argv)} failed: {r.stderr.strip()}")
    return r


def scan_file_hits(path, rel, terms):
    """All hits (exceptions NOT applied — apply works pre-exception)
    in one file, with spans."""
    try:
        text = Path(path).read_text()
    except (OSError, UnicodeDecodeError):
        return []
    out = []
    for line_no, line in enumerate(text.splitlines(), 1):
        out.extend(cs.scan_line(line, rel, line_no, terms))
    return out


def plan_actions(packet, repo_dir, terms, table):
    """Compute per-hit actions against the CURRENT tree. Pure: no
    writes. Each action: {hit, kind, detail, state} where state is
    'pending' (work to do) or 'already' (idempotent no-op)."""
    root = Path(repo_dir)
    relocate_dir = (packet.get("relocate_dir") or DEFAULT_RELOCATE_DIR).strip("/")
    actions = []
    sub_groups = {}  # (file, term_hash) -> [hits]
    for h in packet["hits"]:
        disp = h["disposition"]
        if disp == "substitute":
            sub_groups.setdefault((h["file"], h["term_hash"]), []).append(h)
        elif disp == "generalize":
            text = (root / h["file"]).read_text()
            anchor, draft = h["anchor"], h["draft"]
            count = text.count(anchor)
            if count == 1:
                actions.append({"hit": h, "kind": "generalize", "state": "pending"})
            elif count > 1:
                raise SystemExit(
                    f"{h['id']}: anchor {anchor!r} occurs {count} times in "
                    f"{h['file']} — ambiguous; widen the anchor in the packet"
                )
            elif draft and draft in text:
                actions.append({"hit": h, "kind": "generalize", "state": "already"})
            elif h.get("applied"):
                actions.append({"hit": h, "kind": "generalize", "state": "already"})
            else:
                raise SystemExit(
                    f"{h['id']}: anchor {anchor!r} not found in {h['file']} "
                    "and draft not present — the tree moved; rebuild the packet"
                )
        elif disp == "relocate":
            src, dst = root / h["file"], root / relocate_dir / h["file"]
            # A stub left at the original path makes src exist again —
            # the packet's applied flag is what marks this done.
            state = "already" if (h.get("applied") or not src.exists()) else "pending"
            actions.append({"hit": h, "kind": "relocate", "state": state,
                            "shared_file": True})
        elif disp == "except":
            exc_path = root / "sanitize-exceptions.json"
            doc = json.loads(exc_path.read_text()) if exc_path.exists() else {"exceptions": []}
            found = False
            for e in doc.get("exceptions") or []:
                if e.get("class") == "topic" and cs.path_matches(h["file"], e.get("path", "")):
                    terms_list = e.get("terms")
                    if not terms_list or h["term"] in terms_list:
                        found = True
            actions.append({"hit": h, "kind": "except",
                            "state": "already" if found else "pending"})
    for (path, term_hash), hs in sub_groups.items():
        fpath = root / path
        repl = hs[0].get("replacement") or table[term_hash]
        present = False
        if fpath.exists():
            for hit in scan_file_hits(fpath, path, terms):
                if hit.kind == "identifier" and digest_for_hit(hit) == term_hash:
                    present = True
        if present:
            state = "pending"
        elif fpath.exists() and repl in fpath.read_text():
            state = "already"
        else:
            raise SystemExit(
                f"{hs[0]['id']}: identifier (hash {term_hash[:12]}…) not found in "
                f"{path} and replacement absent — the tree moved; rebuild the packet"
            )
        for h in hs:
            actions.append({"hit": h, "kind": "substitute", "state": state,
                            "replacement": repl})
    return actions


def execute_actions(packet, repo_dir, terms, actions):
    root = Path(repo_dir)
    relocate_dir = (packet.get("relocate_dir") or DEFAULT_RELOCATE_DIR).strip("/")
    if relocate_dir != STAGING_DIRNAME:
        print(f"WARNING: relocate_dir is {relocate_dir!r}, not {STAGING_DIRNAME!r} — "
              "the checker's staging exclusion names private-staging, so the "
              "closure scan will still flag staged files.")
    pending = [a for a in actions if a["state"] == "pending"]
    # --- generalize + substitute: exact text edits, grouped by file
    edits = {}  # file -> list of (mode, payload)
    for a in pending:
        if a["kind"] == "generalize":
            edits.setdefault(a["hit"]["file"], []).append(
                ("replace", a["hit"]["anchor"], a["hit"]["draft"]))
        elif a["kind"] == "substitute":
            edits.setdefault(a["hit"]["file"], []).append(
                ("substitute", a["hit"]["term_hash"], a["replacement"]))
    for rel, ops in edits.items():
        fpath = root / rel
        text = fpath.read_text()
        lines = text.splitlines(keepends=True)
        for op in ops:
            if op[0] == "replace":
                if text.count(op[1]) != 1:
                    raise SystemExit(f"apply drifted mid-run: anchor in {rel} no longer unique")
                text = text.replace(op[1], op[2], 1)
                lines = text.splitlines(keepends=True)
            else:
                _, term_hash, repl = op
                for i, line in enumerate(lines):
                    spans = [
                        (h.start, h.end)
                        for h in cs.scan_line(line.rstrip("\n"), rel, i + 1, terms)
                        if h.kind == "identifier" and digest_for_hit(h) == term_hash
                    ]
                    for start, end in sorted(spans, reverse=True):
                        line = line[:start] + repl + line[end:]
                    lines[i] = line
                text = "".join(lines)
        fpath.write_text(text)
    # --- relocate: one git-mv per file, optional stub
    relocated = set()
    for a in pending:
        if a["kind"] != "relocate":
            continue
        rel = a["hit"]["file"]
        if rel in relocated:
            continue
        relocated.add(rel)
        src, dst = root / rel, root / relocate_dir / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        tracked = git(root, "ls-files", "--error-unmatch", rel, check=False).returncode == 0
        if tracked:
            git(root, "mv", rel, str(Path(relocate_dir) / rel))
        else:
            os.rename(src, dst)
        stub = next((x["hit"].get("stub") for x in pending
                     if x["kind"] == "relocate" and x["hit"]["file"] == rel
                     and x["hit"].get("stub")), None)
        if stub:
            (root / rel).write_text(stub if stub.endswith("\n") else stub + "\n")
    # --- except: append to sanitize-exceptions.json (checker-validated)
    exc_hits = [a["hit"] for a in pending if a["kind"] == "except"]
    if exc_hits:
        exc_path = root / "sanitize-exceptions.json"
        doc = json.loads(exc_path.read_text()) if exc_path.exists() else {"exceptions": []}
        entries = doc.setdefault("exceptions", [])
        for h in exc_hits:
            target = None
            for e in entries:
                if e.get("class") == "topic" and e.get("path") == h["file"] and e.get("terms"):
                    target = e
                    break
            if target is not None:
                if h["term"] not in target["terms"]:
                    target["terms"].append(h["term"])
            else:
                entries.append({"path": h["file"], "class": "topic",
                                "terms": [h["term"]], "reason": h["reason"]})
        exc_path.write_text(json.dumps(doc, indent=2) + "\n")
        cs.load_exceptions(root)  # raises unless the file is valid (topic-only, reasoned)
    git(root, "add", "-A")


def pr_body(packet, branch, regate):
    lines = [
        f"Sanitize pass for **{packet['repo']}** — packet "
        f"`publish-registry/packets/{packet['repo']}.json` in fleet-kit.",
        "",
        f"Branch `{branch}` was produced by `scripts/sanitize_packet.py apply` "
        "and re-gated on the branch: " + regate + ".",
        "",
        "| Hit | File | Class | Disposition |",
        "|---|---|---|---|",
    ]
    for h in packet["hits"]:
        where = f"{h['file']}:{h['line']}"
        what = (f"identifier (hash {h['term_hash'][:12]}…)" if h["class"] == "identifier"
                else f"topic: {h['term']}")
        lines.append(f"| {h['id']} | {where} | {what} | {h['disposition']} |")
    lines += [
        "",
        "**Approval boundary:** merging is Andrew's word. Merging this PR does "
        "NOT itself clear the \"Sanitizer needed\" tag — the tag is "
        "build-generated from the fleet overlay and clears when the overlay is "
        "regenerated after merge (`scripts/pull_sanitize.py --write`) and "
        "shows this repo passing.",
    ]
    reloc = [h for h in packet["hits"] if h["disposition"] == "relocate"]
    if reloc:
        lines.append(
            "**Relocated files** now sit under the packet's relocate dir — "
            "off the scanned surface, but in a public repo they are still in "
            "a public repo (not secret). The follow-up move behind the gate, "
            "or deletion, remains an owner decision."
        )
    return "\n".join(lines)


def open_pr_api(repo_slug, branch, base, title, body, token):
    payload = json.dumps({"title": title, "head": branch, "base": base,
                          "body": body}).encode()
    req = urllib.request.Request(
        f"{API}/repos/{repo_slug}/pulls", data=payload, method="POST",
        headers={"Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28",
                 "Authorization": f"Bearer {token}",
                 "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())["html_url"]
    except urllib.error.HTTPError as e:
        raise SystemExit(f"PR creation failed: HTTP {e.code} — the token needs "
                         "pull-requests write on the repo; the branch is pushed, "
                         "open the PR from the branch by hand.")


def cmd_apply(args):
    terms = load_terms()
    packet_path = Path(args.packet)
    packet = load_packet(packet_path)
    repo_dir = Path(args.repo_dir)
    if git(repo_dir, "rev-parse", "--is-inside-work-tree", check=False).returncode != 0:
        raise SystemExit(f"{repo_dir} is not a git working tree — apply works on a checkout")
    table = load_substitutions(repo_dir, terms)

    errors = validate_filled(packet, repo_dir, terms, table)
    if errors:
        print("APPLY REFUSED — fix the packet/tree first (nothing was touched):")
        for e in errors:
            print("  - " + e)
        return 1
    actions = plan_actions(packet, repo_dir, terms, table)
    for a in actions:
        print(f"  {a['hit']['id']}  {a['kind']:<10} {a['state']}")
    pending = [a for a in actions if a["state"] == "pending"]

    branch = args.branch or f"sanitize-pass/{today()}"
    exists = git(repo_dir, "rev-parse", "--verify", f"refs/heads/{branch}",
                 check=False).returncode == 0
    current = git(repo_dir, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    if not pending and packet.get("applied"):
        print(f"packet already applied ({packet['applied']['at']}, branch "
              f"{packet['applied']['branch']}) — nothing to do.")
        return 0
    if current != branch:
        git(repo_dir, "checkout", branch) if exists else git(
            repo_dir, "checkout", "-b", branch)
    if pending:
        execute_actions(packet, repo_dir, terms, actions)
        git(repo_dir, "commit", "-m",
            f"Sanitize pass: {packet['repo']} ({len(pending)} hit(s) remediated)")
    commit = git(repo_dir, "rev-parse", "HEAD").stdout.strip()

    # Re-gate: the packet closes only on a clean-or-excepted branch scan.
    unexcepted, excepted = scan_detailed(repo_dir, terms)
    if unexcepted:
        print(f"RE-GATE FAILED — {len(unexcepted)} unexcepted hit(s) remain on {branch}:")
        for h in unexcepted:
            print("  HIT  " + h.render())
        print("The branch commit stands for inspection; the packet stays OPEN.")
        return 1
    regate = (f"clean ({len(excepted)} excepted topic hit(s)) — checker exit 0 "
              f"on branch {branch}")
    print("RE-GATE: " + regate)

    for a in actions:
        a["hit"]["applied"] = True
    packet["status"] = "applied-clean"
    packet["applied"] = {"at": now_iso(), "branch": branch, "commit": commit,
                         "regate": regate,
                         "results": {a["hit"]["id"]: a["state"] for a in actions}}
    packet_path.write_text(json.dumps(packet, indent=2, sort_keys=True) + "\n")
    print(f"packet updated: {packet_path} (status applied-clean)")

    if args.push:
        r = git(repo_dir, "push", "-u", "origin", branch, check=False)
        if r.returncode != 0:
            print("PUSH FAILED (branch is committed locally): " + r.stderr.strip())
            print("Push it from an authenticated checkout, then open the PR.")
            return 1
        print(f"pushed {branch}")
    if args.pr:
        if not args.push:
            print("--pr needs --push (the branch must be on the remote first)")
            return 1
        token = os.environ.get("GITHUB_TOKEN") or os.environ.get("FLEET_PULL_TOKEN")
        slug = args.repo_slug or packet["repo"]
        if not token or "/" not in slug:
            print("PR not opened: set GITHUB_TOKEN and --repo-slug <owner/name>.")
            return 1
        base = git(repo_dir, "symbolic-ref", "refs/remotes/origin/HEAD",
                   check=False).stdout.strip().rsplit("/", 1)[-1] or "main"
        url = open_pr_api(slug, branch, base,
                          f"Sanitize pass: {packet['repo']}",
                          pr_body(packet, branch, regate), token)
        print(f"PR opened: {url}")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Sanitize pass — remediate gate failures.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="scan a repo fresh and emit a packet")
    b.add_argument("--repo", help="fleet repo slug (pulled via the GitHub API)")
    b.add_argument("--repo-dir", help="local tree to scan instead of pulling")
    b.add_argument("--repo-name", help="packet label for --repo-dir mode")
    b.add_argument("--out", help="packet path (default: publish-registry/packets/<repo>.json)")
    b.add_argument("--refresh-overlay", action="store_true",
                   help="regenerate the fleet overlay first (pull_sanitize.py --write)")
    b.set_defaults(fn=cmd_build)

    s = sub.add_parser("show", help="print a packet summary")
    s.add_argument("--packet", required=True)
    s.set_defaults(fn=cmd_show)

    a = sub.add_parser("apply", help="execute a filled packet on a branch, then re-gate")
    a.add_argument("--packet", required=True)
    a.add_argument("--repo-dir", required=True)
    a.add_argument("--branch")
    a.add_argument("--push", action="store_true")
    a.add_argument("--pr", action="store_true")
    a.add_argument("--repo-slug", help="owner/name for --pr (default: the packet's repo)")
    a.set_defaults(fn=cmd_apply)

    args = ap.parse_args(argv)
    if args.cmd == "build" and bool(args.repo) == bool(args.repo_dir):
        ap.error("build needs exactly one of --repo / --repo-dir")
    if args.cmd == "build" and args.repo_dir and not args.repo_name:
        ap.error("--repo-dir mode needs --repo-name")
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
