# ADR-0003 — One repo per component

**Date** 2026-11-23 · **Status** accepted · **Decided by** Ganesh

## Decision
`FullProdProject/` is a plain folder, not a repo. Each component gets its own:
`Brain` (this repo, `BrainForTaskManager`), then `Server`, then `ml-service`.

## Cost, stated honestly
Server consumes Brain as a versioned Swift package from a git URL, so every Brain
change needs a tag and a bump in Server. For a solo developer that is real friction.

## Mitigation
`.package(path: "../Brain")` for local development, a pinned git tag in CI.
Instant iteration locally, reproducible builds in CI.

## Cross-cutting docs
Live in `Brain/docs/` for now, since Brain is the only repo. Extracted to their
own repo when Server starts. Avoiding structure we do not yet need.
