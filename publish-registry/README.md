# Publish registry

One copy of every fleet repo's `publish.json`, vendored here so builds can
read the whole fleet's publish intent from one place.

- **Source of truth is each repo's own `publish.json`** (repo root). The
  files here are copies: `<repo>.json` mirrors
  `andrewdhorowitz/<repo>/publish.json`. When a manifest changes, its
  registry copy changes in the same push — drift between the two is a
  defect, checked by the weekly site-health watch.
- **Schema:** [`publish.schema.json`](publish.schema.json) — every
  manifest (and every copy here) must validate against it.
- **Who reads this:** the portfolio repo's publish-gate workflow
  (`.github/workflows/publish-gate.yml` in `andrewdhorowitz.github.io`)
  checks this repo out at CI time and fails the portfolio build if any
  page links to a host declared in any manifest's `private_hosts`.
  The private Family Cards section is generated from these copies too.
- **`section` object:** opts a project into the private index section
  (gated; never linked publicly). `family_visible` is an explicit yes —
  it is for surfaces that carry the family's own data (the cards, the
  calendar view), not for general tooling. The optional `also` list
  names companion surfaces rendered from the same manifest (e.g. the
  Family Cards entry's calendar-view companion).

First pass (Oct 29, 2026): andrewdhorowitz.github.io,
routines-and-streaks, aimf-protocol, family-cards-demo, family-cards,
fleet-kit.

**Intentional dual listing (Andrew, Oct 29, 2026):** the publishing
system lists itself twice on purpose — the restructure work appears
as a Projects entry (in the portfolio manifest's `also` list) and the
manifest/gate/index machinery appears as a Shared Infrastructure entry
(in fleet-kit's `also` list). Tooling must not flag the pair as a
duplicate-name defect.
