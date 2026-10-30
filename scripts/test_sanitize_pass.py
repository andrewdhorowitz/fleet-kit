#!/usr/bin/env python3
"""End-to-end check for the sanitize pass (scripts/sanitize_packet.py).

Builds a synthetic fixture repo in a temp dir — invented content
only, seeded with one identifier hit (an unlisted address), one
generalizable category hit, one relocatable file, and one
except-able category hit — then runs the real tools:

    check (expect FAIL) -> packet build -> fill dispositions ->
    refusal checks -> apply on a branch -> re-gate (expect PASS)
    -> idempotent re-apply (expect no-op)

Exits 0 only if every stage behaves. Run:
    python3 scripts/test_sanitize_pass.py
Stdlib only, like the rest of the gate family.

Note on literals: the fixture's address is assembled from parts
because identifier hits cannot be excepted — the assembled value
must never sit in this file (or anywhere in fleet-kit) as a
contiguous string. The category words in the fixture strings are
excepted for this file in fleet-kit's sanitize-exceptions.json,
the same sanctioned pattern the demo uses for its filter tests.
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHECK = HERE / "check_sanitize.py"
PACKET = HERE / "sanitize_packet.py"
sys.path.insert(0, str(HERE))
import check_sanitize as cs

EMAIL = "someone.unlisted" + "@" + "privatemail" + ".net"
REPLACEMENT = "kid.coordinator" + "@" + "demo-mail.invalid"
BRANCH = "sanitize-pass/test-run"

FAILURES = []


def run(argv, cwd=None, expect=0):
    r = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
    if expect is not None and r.returncode != expect:
        FAILURES.append(f"{' '.join(str(a) for a in argv)}: exit {r.returncode} "
                        f"(wanted {expect})\n{r.stdout}\n{r.stderr}")
    return r


def check(cond, msg):
    if cond:
        print("  ok — " + msg)
    else:
        FAILURES.append(msg)
        print("  FAIL — " + msg)


def git(repo, *argv):
    return run(["git", "-C", str(repo), *argv])


def main():
    terms = cs.Terms(json.loads((HERE / "sanitize_terms.json").read_text()))
    email_hash = cs.hash_term(EMAIL)
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp) / "fixture"
        (repo / "notes").mkdir(parents=True)
        (repo / "index.md").write_text(
            "# Demo fixture\n\n"
            f"Contact the coordinator at {EMAIL} for the schedule.\n\n"
            "The weekly therapy session moved to Tuesdays.\n"
        )
        (repo / "words.md").write_text(
            "The filter list includes the phrase support group.\n"
        )
        (repo / "notes" / "visit-notes.md").write_text(
            "# Visit notes\n\nA diagnosis summary lives here.\n"
        )
        (repo / "sanitize-substitutions.json").write_text(json.dumps({
            "version": 1,
            "substitutions": [
                {"identifier_hash": email_hash, "replacement": REPLACEMENT,
                 "note": "invented stand-in for the fixture address"},
            ],
        }, indent=2) + "\n")
        git(repo, "init", "-b", "main")
        git(repo, "config", "user.email", "test@example.invalid")
        git(repo, "config", "user.name", "Sanitize Pass Test")
        git(repo, "add", "-A")
        git(repo, "commit", "-m", "fixture")

        print("stage 1 — gate on the seeded fixture (must FAIL)")
        r = run([sys.executable, str(CHECK), "--root", str(repo)], expect=1)
        for line in r.stdout.splitlines():
            if line.startswith("HIT"):
                print("  before: " + line)

        print("stage 2 — packet build")
        packet_path = Path(tmp) / "packet.json"
        run([sys.executable, str(PACKET), "build", "--repo-dir", str(repo),
             "--repo-name", "sanitize-pass-fixture", "--out", str(packet_path)])
        raw = packet_path.read_text()
        packet = json.loads(raw)
        check(len(packet["hits"]) == 4, f"packet has 4 hits (got {len(packet['hits'])})")
        check(EMAIL not in raw, "packet does NOT contain the identifier value")
        by_class = {}
        for h in packet["hits"]:
            key = (h["class"], h.get("term") or "identifier")
            by_class[key] = h
        ident = next(h for h in packet["hits"] if h["class"] == "identifier")
        check(ident["term_hash"] == email_hash, "identifier recorded as hash + file/line only")
        check("quote" not in ident, "identifier hit carries no quoted context")
        therapy = next(h for h in packet["hits"] if h.get("term") == "therapy")
        diagnosis = next(h for h in packet["hits"] if h.get("term") == "diagnosis")
        supgroup = next(h for h in packet["hits"] if h.get("term") == "support group")
        check(therapy["anchor"] == "therapy", "topic hit carries its anchor text")

        def save(p):
            packet_path.write_text(json.dumps(p, indent=2, sort_keys=True) + "\n")

        def apply(expect=0):
            return run([sys.executable, str(PACKET), "apply", "--packet",
                        str(packet_path), "--repo-dir", str(repo),
                        "--branch", BRANCH], expect=expect)

        print("stage 3 — refusal checks (nothing may be touched)")
        head_before = git(repo, "rev-parse", "HEAD").stdout.strip()
        therapy["disposition"] = "except"  # no reason -> must refuse
        save(packet)
        apply(expect=1)
        ident["disposition"] = "except"  # identifiers can never be excepted
        ident["reason"] = "n/a"
        therapy["disposition"] = None
        save(packet)
        apply(expect=1)
        check(git(repo, "rev-parse", "HEAD").stdout.strip() == head_before,
              "refusals left the tree untouched")
        check(git(repo, "branch", "--list", BRANCH).stdout.strip() == "",
              "refusals created no branch")

        print("stage 4 — bad anchor fails the whole apply")
        ident["disposition"] = "substitute"
        therapy["disposition"] = "generalize"
        therapy["anchor"] = "a phrase that is not in the file"
        therapy["draft"] = "appointment"
        diagnosis["disposition"] = "relocate"
        supgroup["disposition"] = "except"
        supgroup["reason"] = "Fixture: category vocabulary inside a filter-word list."
        save(packet)
        apply(expect=1)
        check(git(repo, "rev-parse", "HEAD").stdout.strip() == head_before,
              "anchor failure left the tree untouched")

        print("stage 5 — the real apply")
        therapy["anchor"] = "therapy"
        diagnosis["stub"] = "Visit notes moved to private staging."
        save(packet)
        r = apply(expect=0)
        check("RE-GATE: clean" in r.stdout, "re-gate clean on the branch")
        packet = json.loads(packet_path.read_text())
        check(packet["status"] == "applied-clean", "packet closed as applied-clean")
        index = (repo / "index.md").read_text()
        check(REPLACEMENT in index and EMAIL not in index,
              "substitute swapped the identifier for the invented replacement")
        check("weekly appointment session" in index,
              "generalize applied the draft as an exact replacement")
        staged = repo / "private-staging" / "notes" / "visit-notes.md"
        check(staged.exists() and "diagnosis" in staged.read_text(),
              "relocate moved the file into private-staging intact")
        stub = (repo / "notes" / "visit-notes.md").read_text()
        check(stub.startswith("Visit notes moved to private staging."),
              "relocate left the generic stub at the original path")
        exc = json.loads((repo / "sanitize-exceptions.json").read_text())
        check(any(e.get("terms") == ["support group"] and e.get("reason")
                  for e in exc["exceptions"]),
              "except recorded a reasoned, term-scoped exception")

        print("stage 6 — gate after (must PASS) + idempotent re-apply")
        r = run([sys.executable, str(CHECK), "--root", str(repo)], expect=0)
        for line in r.stdout.splitlines():
            if line.startswith(("EXCEPTED", "0 unexcepted")):
                print("  after: " + line)
        r = apply(expect=0)
        check("already applied" in r.stdout, "re-apply is a reported no-op")

    if FAILURES:
        print(f"\n{len(FAILURES)} FAILURE(S)")
        return 1
    print("\nALL STAGES PASSED — packet -> dispositions -> branch apply -> re-gate clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
