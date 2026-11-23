# ADR-0001 — Hummingbird 2 for the server

**Date** 2026-11-22 · **Status** accepted

## Context
The server must run on a 2 vCPU / 8–12 GB VM alongside a Python ML container.
Vapor is the obvious alternative.

## Decision
Hummingbird 2 (2.29.0, released 2026-11-19).

## Reasoning
Lighter memory profile suits the target VM. The satellite packages we need are
all actively maintained in the same org and verified current: `hummingbird-postgres`
1.1.0, `swift-jobs` 1.4.0, `swift-jobs-postgres` 1.5.0, `hummingbird-auth` 2.5.0,
`swift-openapi-hummingbird` 2.1.0.

## Risk accepted
`swift-openapi-hummingbird` sat at 2.0.1 for two years before 2.1.0 in Sept 2026.
Low activity — but it is a thin adapter over generated code, so the blast radius
is small.
