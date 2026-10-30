# Sanitize-pass packets

One JSON per repo being remediated, produced by
[`scripts/sanitize_packet.py`](../../scripts/sanitize_packet.py)
(`build`), filled in by the operator, and executed by the same
tool (`apply`). A packet is the work order behind a repo's
"Sanitizer needed" tag: every unexcepted gate hit, one
`disposition` slot per hit (`generalize` / `substitute` /
`relocate` / `except`), and — after a successful apply — the
recorded branch, commit, and re-gate result that closed it.

**Privacy rule (load-bearing):** this repo is public, so
identifier hits are recorded as SHA-256 digests + file/line only.
Never the value, never quoted context — a packet must not publish
the identifiers it exists to remove. (The same reasoning hashes
the checker's term file.) Topic hits carry the term and a quoted
window: topic vocabulary is general category language, and the
quotes are what make a generalization draft reviewable.

Packets for repos that pass the gate are not kept here — a packet
exists only while a repo has unexcepted hits to work through, and
a closed packet (`status: applied-clean`) is the record that the
work was done and re-gated.
