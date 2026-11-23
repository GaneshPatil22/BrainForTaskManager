# ADR-0007 — Supabase asymmetric JWT (JWKS)

**Date** 2026-11-23 · **Status** accepted · **Applies to** Server repo

## Context
Supabase projects created after 2025-10-01 default to asymmetric JWT signing
keys. Ganesh confirmed this will be a **new project**.

## Decision
Verify tokens against the JWKS endpoint at
`https://<project>.supabase.co/auth/v1/.well-known/jwks.json`, with key caching
and rotation handling. **No HS256 shared-secret path will be written.**

## Related — RLS
Per Ganesh's decision, the server connects as a privileged role and `user_id`
filtering in application code is the real boundary. RLS stays enabled but is
documented as **inert under a bypassing role** — it is not a second safety net
and will not be described as one. The actual control is a repository layer where
no query can be constructed without a `UserID`, plus the cross-user isolation
test suite.
