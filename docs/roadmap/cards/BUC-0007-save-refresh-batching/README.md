# BUC-0007 Save and refresh batching

- Status: deferred
- Priority: medium
- Origin: downstream LIRIS feedback
- Last reviewed: 2026-10-19
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: none linked
- PR: none linked

## Problem and decision

Editing a dependency can require sync, save, and importer refresh operations.
The older card proposed combining them. Keep this deferred until a measured
workflow shows that a small explicit composition is insufficient.

Do not add implicit project watching, dependency scheduling, or a generic
orchestration mode. Beam is not a replacement for Lake.

## Evidence and next action

This is a historical workflow request without a fresh reduced performance or
correctness case. Compare a concrete multi-file edit against documented
[sync/save recovery](../../../SYNC_AND_DIAGNOSTICS.md) before designing batching.
Ordering, partial failure, cancellation, and stale results would need explicit
semantics if a batch operation were justified.

## Current workaround and removal target

Keep dependency sync/save and importer refresh explicit. No implementation
or removable shim is assigned to this card.
