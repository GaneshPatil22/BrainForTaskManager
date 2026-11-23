# ADR-0005 — Embeddings run locally, never via API

**Date** 2026-11-22 · **Status** accepted

## Context
Gemini Embedding 1 and 2 are capped at **1,000 RPD** on the free tier — roughly
50 users before the quota is gone. Verified from Ganesh's AI Studio account.

## Decision
Embeddings run in our own container (T1). Candidates, to be benchmarked on real
Hinglish captures in B2 rather than chosen on reputation:

- `granite-embedding-107m-multilingual-r2` — 97M params, Apache 2.0, reported
  strongest sub-100M multilingual retrieval
- `multilingual-e5-small` — smaller, well-proven, ONNX available
- `EmbeddingGemma-300M` — larger, runs under 200 MB quantised

Served over HTTP from `ml-service` behind an adapter with fake and replay
implementations. Exported to ONNX for Linux serving (Core ML does not run on Linux).

## Consequences
Free, offline, private, unmetered, ~400 MB resident. Removes embeddings from the
quota budget entirely. Model version is stamped on every stored vector; changing
the model is a re-embedding migration, not a silent swap.
