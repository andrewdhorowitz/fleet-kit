#!/usr/bin/env python3
"""Sanitize gate — public/demo surfaces must be PUBLIC AND GENERIC.

Andrew's rule (Oct 29, 2026): the main page is public and generic, and
anything labeled a Demo must meet the same bar. Content meant for a
public or demo surface that is NOT sanitized — a family identifier, or
an off-limit topic — falls back to OWNER-ONLY: it does not ship
publicly, and it does not drop to the family tier instead. Live family
apps with live data are a separate track (family tier, private
section) and are not this gate's scope.

This checker is shared infrastructure (fleet-kit). Project repos never
depend on each other; both public-bound repos (the portfolio and the
demo) check fleet-kit out in CI and run this script against their own
tree — see each repo's .github/workflows/sanitize-gate.yml.

Classes:
  identifier — definite hits: family names, family emails (the known
    ones, and ANY email-shaped string not on the allowlist), and
    home/school/street identifiers. Stored in the terms file as
    SHA-256 hashes, because fleet-kit is public and a plaintext
    forbidden-names list would itself publish the identifiers (the
    same reason family-cards-demo's CI uses generic PII shapes).
    Identifier hits can NOT be excepted by a repo-local file.
  topic — off-limit category terms (therapy / support group /
    medical / dental / legal / financial specifics) and amount
    patterns, from Andrew's standing sensitive categories. Every hit
    is quoted so false positives stay visible and tunable. A repo may
    carry sanitize-exceptions.json with path+term-scoped, reasoned
    exceptions for the topic class ONLY (e.g. a redaction filter's
    own word list, or test fixtures with invented data that exist to
    prove the filter works). Excepted hits are still printed.

Andrew's own public identity (his name, his handles/domains, his
public email addresses) is allowlisted in the terms file and masked
before scanning — he is public on purpose.

Usage:
    check_sanitize.py --root <dir> [--terms <sanitize_terms.json>]
    check_sanitize.py --hash-term "<term or email>"   # maintenance

Exit 0: no unexcepted hits. Exit 1: at least one unexcepted hit,
each printed with file, line, class and a quoted window.
Stdlib only — a display/CI build never needs a package install.
"""

import argparse
import fnmatch
import hashlib
import json
import re
import sys
from pathlib import Path

TEXT_EXTS = {
    ".html", ".htm", ".md", ".json", ".js", ".mjs", ".txt", ".xml",
    ".svg", ".css", ".py", ".yml", ".yaml", ".toml", ".sh",
    ".webmanifest", ".csv",
}
SKIP_EXTS = {
    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".woff", ".woff2",
    ".ttf", ".eot", ".zip", ".gz", ".mp4", ".webp", ".avif", ".lock",
}
SKIP_DIRS = {
    "node_modules",
    "__pycache__",
    # The sanitize pass's relocation staging (scripts/sanitize_packet.py):
    # content whose disposition is `relocate` is git-mv'd here, off the
    # served surface, pending its move behind the gate or deletion.
    # The exclusion is a named, visible decision (see the spec's
    # sanitize-pass addendum) — staged content in a public repo is
    # still IN a public repo, merely off-surface; it is not secret.
    "private-staging",
}
SELF_FILES = {
    "sanitize_terms.json",
    "check_sanitize.py",
    "sanitize-exceptions.json",
    # The generated overlay quotes failing matches verbatim; scanning
    # it would re-flag the quotes forever (gate output is not content).
    "sanitize-overlay.json",
}
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
# RFC 2606 reserved example domains (and any *.invalid) can never be
# a real address or identify anyone — specs and probe scripts use
# them deliberately (aimf's counterparty@example.com, the Firebase
# converger's @example.invalid probe). They are not hits.
RESERVED_EMAIL_DOMAINS = {"example.com", "example.org", "example.net"}
TOKEN_RE = re.compile(r"[A-Za-z0-9]+")
MAX_FILE_BYTES = 3_000_000
QUOTE_PAD = 90


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def norm_tokens(text):
    return [t.lower() for t in TOKEN_RE.findall(text)]


def hash_term(term):
    """The digest a maintainer pastes into sanitize_terms.json."""
    if "@" in term:
        return sha(term.lower().strip())
    return sha(" ".join(norm_tokens(term)))


class Terms:
    def __init__(self, doc):
        self.allowlist = [re.compile(p, re.I) for p in doc.get("allowlist_patterns", [])]
        ident = doc.get("identifiers", {})
        self.ident_hashes = {}  # digest -> "identifier/<category>"
        for category, digests in (ident.get("hashed_terms") or {}).items():
            for d in digests:
                self.ident_hashes[d] = f"identifier/{category}"
        self.email_hashes = set(ident.get("hashed_emails") or [])
        topics = doc.get("topics", {})
        self.topic_phrases = {}  # normalized token key -> display phrase
        for phrase in topics.get("terms") or []:
            self.topic_phrases[" ".join(norm_tokens(phrase))] = phrase
        self.topic_patterns = [
            (p["id"], re.compile(p["regex"])) for p in topics.get("patterns") or []
        ]

    def mask(self, line):
        out = line
        for rx in self.allowlist:
            out = rx.sub(lambda m: " " * len(m.group(0)), out)
        return out


class Hit:
    def __init__(self, path, line_no, kind, term, label, quote):
        self.path, self.line_no, self.kind = path, line_no, kind
        self.term, self.label, self.quote = term, label, quote
        self.exception_reason = None
        # Character span of the match within its line (start, end).
        # Set by scan_line; consumed by fleet-kit's sanitize pass
        # (scripts/sanitize_packet.py) for anchored replacements.
        self.start = None
        self.end = None

    def render(self):
        return f"{self.path}:{self.line_no}  [{self.label}]  …{self.quote}…"


def quote_window(line, start, end):
    lo = max(0, start - QUOTE_PAD)
    hi = min(len(line), end + QUOTE_PAD)
    return line[lo:hi].replace("\t", " ").strip()


def scan_line(line, path, line_no, terms):
    masked = terms.mask(line)
    raw = []  # (start, end, kind, term, label)
    for m in EMAIL_RE.finditer(masked):
        email = m.group(0)
        domain = email.rsplit("@", 1)[-1].lower()
        if domain in RESERVED_EMAIL_DOMAINS or domain.endswith(".invalid"):
            continue
        if sha(email.lower()) in terms.email_hashes:
            label, term = "identifier/email (family)", email
        else:
            label, term = "identifier/email (unlisted)", email
        raw.append((m.start(), m.end(), "identifier", term, label))
    tokens = [(m.group(0).lower(), m.start(), m.end()) for m in TOKEN_RE.finditer(masked)]
    for n in (1, 2, 3):
        for i in range(len(tokens) - n + 1):
            key = " ".join(t[0] for t in tokens[i : i + n])
            start, end = tokens[i][1], tokens[i + n - 1][2]
            digest = sha(key)
            if digest in terms.ident_hashes:
                raw.append((start, end, "identifier", key, terms.ident_hashes[digest]))
            elif key in terms.topic_phrases:
                raw.append((start, end, "topic", terms.topic_phrases[key],
                            f"topic/{terms.topic_phrases[key]}"))
    for pid, rx in terms.topic_patterns:
        for m in rx.finditer(masked):
            raw.append((m.start(), m.end(), "topic", pid, f"topic/{pid}"))
    # Drop overlaps: identifiers beat topics; longer spans beat shorter.
    raw.sort(key=lambda r: (0 if r[2] == "identifier" else 1, -(r[1] - r[0]), r[0]))
    kept, spans = [], []
    for r in raw:
        if any(r[0] < e and s < r[1] for s, e in spans):
            continue
        spans.append((r[0], r[1]))
        kept.append(r)
    kept.sort(key=lambda r: r[0])
    out = []
    for start, end, kind, term, label in kept:
        hit = Hit(path, line_no, kind, term, label, quote_window(line, start, end))
        hit.start, hit.end = start, end
        out.append(hit)
    return out


def iter_files(root):
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(root)
        if any(part.startswith(".") or part in SKIP_DIRS for part in rel.parts[:-1]):
            continue
        if p.name in SELF_FILES or p.suffix.lower() in SKIP_EXTS:
            continue
        if p.suffix.lower() not in TEXT_EXTS and p.suffix != "":
            continue
        try:
            if p.stat().st_size > MAX_FILE_BYTES:
                continue
        except OSError:
            continue
        yield p, rel.as_posix()


def load_exceptions(root):
    f = root / "sanitize-exceptions.json"
    if not f.exists():
        return []
    doc = json.loads(f.read_text())
    out = []
    for e in doc.get("exceptions") or []:
        if e.get("class") != "topic":
            raise SystemExit(
                "sanitize-exceptions.json: exceptions apply to the topic class "
                f"only — identifiers are definite hits (entry for {e.get('path')!r})"
            )
        if not e.get("reason"):
            raise SystemExit(
                f"sanitize-exceptions.json: exception for {e.get('path')!r} has no reason"
            )
        out.append(e)
    return out


def path_matches(rel, pattern):
    if pattern.endswith("/"):
        return rel.startswith(pattern)
    if any(c in pattern for c in "*?["):
        return fnmatch.fnmatch(rel, pattern)
    return rel == pattern


def apply_exceptions(hits, exceptions):
    for hit in hits:
        if hit.kind != "topic":
            continue
        for e in exceptions:
            if not path_matches(hit.path, e["path"]):
                continue
            terms = e.get("terms")
            if terms and hit.term not in terms:
                continue
            hit.exception_reason = e["reason"]
            break


def main(argv=None):
    ap = argparse.ArgumentParser(description="Sanitization gate for public/demo surfaces.")
    ap.add_argument("--root", help="repo tree to scan")
    ap.add_argument("--terms", default=str(Path(__file__).with_name("sanitize_terms.json")),
                    help="terms file (default: sanitize_terms.json beside this script)")
    ap.add_argument("--hash-term", help="print the digest for a term/email and exit")
    args = ap.parse_args(argv)

    if args.hash_term:
        print(hash_term(args.hash_term))
        return 0
    if not args.root:
        ap.error("--root is required")

    root = Path(args.root)
    terms = Terms(json.loads(Path(args.terms).read_text()))
    exceptions = load_exceptions(root)

    hits = []
    for p, rel in iter_files(root):
        try:
            data = p.read_bytes()
            if b"\x00" in data[:4096]:
                continue
            text = data.decode("utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for line_no, line in enumerate(text.splitlines(), 1):
            hits.extend(scan_line(line, rel, line_no, terms))
    apply_exceptions(hits, exceptions)

    unexcepted = [h for h in hits if not h.exception_reason]
    excepted = [h for h in hits if h.exception_reason]
    print(f"Sanitize gate — root: {root}")
    for h in unexcepted:
        print("HIT  " + h.render())
    for h in excepted:
        print("EXCEPTED  " + h.render())
        print(f"          reason: {h.exception_reason}")
    print(f"{len(unexcepted)} unexcepted hit(s); {len(excepted)} excepted topic hit(s).")
    if unexcepted:
        print("FAIL — public/demo content must be public AND generic; "
              "unexcepted hits fall back to owner-only and do not ship.")
        return 1
    print("PASS — no unexcepted identifiers or off-limit topics.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
