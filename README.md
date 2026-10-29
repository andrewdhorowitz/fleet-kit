# fleet-kit

Shared kit code for Andrew Horowitz's public projects — error reporting, diagram
tooling, and site snippets, published in one place so the public repos can consume
it directly.

> **Published:** Repo — https://github.com/andrewdhorowitz/fleet-kit

## Why this repo exists

GitHub's rule is that a public repository can only consume shared code (reusable
workflows, snippets, modules) from a public home. The fleet learned that the hard
way with [fleet-ci](https://github.com/andrewdhorowitz/fleet-ci), which hosts the
shared CI workflow for the public repos. This repo is the same pattern for shared
*code*: small, boring, public-safe artifacts that any of the projects can pin or
copy from.

## Consumption model

- Projects **pin or copy** from here. Each folder is a self-contained piece with
  its own README covering adoption, configuration, and limits.
- This repo is the **consumption home, not the workshop**. The source of truth,
  the standards, and the process that produce these artifacts live in a private
  kit repository. Changes are developed and tested there first, then published
  here as clean snapshots — so history here is a series of finished drops, not a
  development log.
- Everything here is deliberately **public-safe**: no credentials, no personal
  data, no internal tooling details. If a piece can't be public-safe, it doesn't
  live here.

## Layers of reuse

The fleet is built in layers, bottom to top: hosted services (each watched for
free-tier limits) → established open-source modules → shared kit code built once
for all projects (this repo is part of that layer) → the projects themselves.
Where a proven open-source module already does a job well, it gets pulled in
rather than reimplemented; each piece documents its license and its free-tier
limits and risks in its own README.

## Contents

| Folder | What it is |
|---|---|
| [`error-reporter/`](error-reporter/) | A dependency-free visitor error-reporting core for static sites and small web apps: one funnel, a shared tier-classification table, pluggable sinks (Firestore, a collector Worker, Sentry, none), and a test suite. |
| [`publish-registry/`](publish-registry/) | One copy of every fleet repo's `publish.json` — the fleet's declared public/private surfaces, plus the manifest schema the copies validate against. |

More pieces (diagram tooling, site snippets) land here as they graduate from the
private kit.

## License

MIT — see [LICENSE](LICENSE).
