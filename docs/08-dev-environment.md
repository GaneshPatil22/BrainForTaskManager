# 08 — Development environment

**Nothing runs on the host.** The host's toolchain is never used, never upgraded,
and never a cause of "works on my machine."

## Why

Verified on this machine, 2026-11-22:

| Host has | Problem |
|---|---|
| Python 3.14.8 | too new — torch, sentence-transformers, onnxruntime lack wheels |
| Swift 6.4.0 | behind the 6.4.3 release |
| no Docker | needed from B5 |

All three disappear if the toolchain lives in images.

## Pinned versions (verified 2026-11-22)

| Component | Version | Source |
|---|---|---|
| Swift | **6.4.3** | `swift:6.4.3-noble` build, `swift:6.4.3-slim` runtime; arm64 + amd64 |
| Python (ml-service) | **3.12** | not the host's 3.14 |
| swift-testing | bundled with the toolchain | `swift-6.4.3-RELEASE` |
| swift-argument-parser | 1.8.2 | EvalCLI |
| swift-log | 1.17.2 | |
| swift-metrics | 2.13.1 | |

Server-side pins (Hummingbird 2.29.0, PostgresNIO 1.33.3, swift-jobs 1.4.0,
swift-jobs-postgres 1.5.0, swift-openapi-generator 1.14.4, swift-openapi-runtime
1.13.4, swift-openapi-hummingbird 2.1.0, hummingbird-auth 2.5.0) live in the
Server repo, recorded here because they were verified in the same pass.

Images are built **multi-arch (arm64 + amd64)** so the M2 Max, an Oracle ARM
instance, and an x86 VPS all run the identical stack.

## Layout

- `.devcontainer/devcontainer.json` — VS Code / CLI dev container
- `docker-compose.yml` — `brain` (Swift) + `ml-service` (Python) + volumes
- `Makefile` — the only interface anyone needs

## CI policy

**Nothing runs on push.** By explicit decision (ADR-0006). CI is
`workflow_dispatch` only — triggered from the Actions tab or
`gh workflow run ci.yml`.

The same checks run locally and identically:

| Local | CI |
|---|---|
| `make test` | job `test` |
| `make eval` | job `eval` (replay mode, offline, free) |
| `make gate` | job `gate` (regression vs. committed baseline) |
| `make lint` | job `lint` |
| `make ci` | all of the above |

`make ci` runs the exact commands the workflow runs. If it passes locally it
passes in CI, or one of them is lying and that is a bug.

## Secrets

`.env` is gitignored; `.env.example` is committed and lists every key with a
comment. CI runs in `replay` mode and therefore **needs no API keys at all** —
which is itself a reason replay mode exists.
