# Beam work cards

A card records one problem, its evidence, the next decision, and the local code
that a fix could remove. This is the public upstream and design backlog; [Status](../STATUS.md)
remains the source of truth for current public behavior.

`BUC` identifies older Beam requests collected from downstream LIRIS work.
`ULC` identifies Lean/Lake upstream opportunities. Existing identifiers are
retained so historical reports remain traceable. The [#262](https://github.com/leanprover/lean-beam/pull/262) native contracts are
ULC-0007 (A), ULC-0008 (B), and ULC-0009 (C); ULC-0010/0011 are independently
landable slices, not substitutes for the complete contracts.

## Next upstream patches

Start with ULC-0004 and ULC-0003 for small typed-diagnostic changes, then
ULC-0001 for authoritative stale-dependency metadata. ULC-0007 is a separate
high-priority Windows filesystem fix. Each has a bounded contract and source evidence.
`open` means ready for discussion or a patch, not scheduled or implemented. No focused upstream
implementation is linked by these cards. Related broad issues are context,
not evidence that the required API is already available.

| Card | Useful outcome | Next action |
| --- | --- | --- |
| [ULC-0004: Preserve RequestError data](cards/ULC-0004-structured-lean-request-error-data/README.md) | Carry typed error data through Lean request handlers. | Small API patch and serialized-response test. |
| [ULC-0003: Tag setup-file diagnostics structurally](cards/ULC-0003-structured-setup-file-progress/README.md) | Identify setup-file progress without matching rendered text. | Tag existing diagnostics before designing another protocol. |
| [ULC-0001: Preserve the stale dependency URI](cards/ULC-0001-structured-stale-dependency-metadata/README.md) | Preserve the authoritative stale URI instead of guessing from history. | Stable diagnostic code/data proposal; high priority. |
| [ULC-0007: Non-following Windows leaf metadata](cards/ULC-0007-nonfollowing-leaf-metadata/README.md) | Observe Windows links/junctions without mistaking failures for absence. | Reduced Windows bug report/patch; high priority. |
| [ULC-0010: Non-consuming child exit observation](cards/ULC-0010-nonconsuming-child-exit/README.md) | Observe child exit before final collection. | Focused retained-identity contract; full lifetime stays separate. |
| [ULC-0011: Creation-time POSIX directory permissions](cards/ULC-0011-creation-time-posix-permissions/README.md) | Establish POSIX directory permissions at creation. | Small filesystem proposal slice; Windows design stays separate. |

## Design candidates

| Card | Decision needed |
| --- | --- |
| [ULC-0012: Declaration scope for tactic contexts](cards/ULC-0012-tactic-declaration-context/README.md) | High-priority candidate: agree declaration metadata and nonblocking header-before-body availability. |
| [ULC-0013: Standalone tactic completion](cards/ULC-0013-standalone-tactic-completion/README.md) | High-priority candidate: define synthesis and pending-declaration inspection before broad finalization APIs. |
| [ULC-0014: Share Lake tooling subprocess machinery](cards/ULC-0014-shared-lake-tooling-helper/README.md) | High-priority candidate: review file-worker reuse and missing configuration/save operation contracts. |
| [ULC-0015: Admit documents before allocating workers](cards/ULC-0015-document-admission-before-worker/README.md) | Candidate: establish a pre-worker admission contract without restricting legitimate external or unsaved editor buffers. |
| [ULC-0016: Retained import artifacts](cards/ULC-0016-retained-import-artifacts/README.md) | Candidate: define snapshot-bound loaded-import identity; replace proposed capture in #368 only after complete support. |
| [ULC-0008: Private directory creation and observation](cards/ULC-0008-private-directory-contract/README.md) | Candidate: agree Windows creation/inspection primitives; retain full private-directory requirements. |
| [ULC-0009: Complete owned subprocess lifetime](cards/ULC-0009-owned-subprocess-lifetime/README.md) | Candidate: agree complete helper lifetime/ownership; async wait alone is insufficient. |
| [BUC-0001: Stale import dependency reporting](cards/BUC-0001-stale-import-dependency-reporting/README.md) | Candidate: reproduce stale-import warnings with unavailable dependency hints. |
| [BUC-0004: runAt diagnostic origin mapping](cards/BUC-0004-runat-diagnostic-origin/README.md) | Candidate: recover the diagnostic-origin prototype and retest a minimal range projection. |

## Deferred work

| Card | Decision needed |
| --- | --- |
| [BUC-0003: Handle continuation state](cards/BUC-0003-handle-continuation-state/README.md) | Deferred: reproduce a concrete continuation ambiguity before adding metadata. |
| [BUC-0005: Todo result filtering](cards/BUC-0005-diagnostics-todo-progress/README.md) | Deferred: reduce todo noise separately from established readiness/progress semantics. |
| [BUC-0007: Save and refresh batching](cards/BUC-0007-save-refresh-batching/README.md) | Deferred: establish a concrete need before adding batching. |
| [ULC-0002: Backend readiness primitive](cards/ULC-0002-backend-readiness-primitive/README.md) | Deferred: no agreed reusable readiness API; not a prerequisite for stale URI metadata. |
| [ULC-0006: Compatibility shim retirement](cards/ULC-0006-compatibility-shim-retirement/README.md) | Deferred to a support-window decision; detailed shim inventory stays in the developer guide. |

## Completed or superseded decisions

These preserve the earlier disposition. Historical test results are dated inside
the cards; importing them does not claim a fresh runtime pass or close unrelated
bugs in the same area.

| Card | Disposition |
| --- | --- |
| [BUC-0002: Tactic-position term ascription failure](cards/BUC-0002-internal-exception-runat-term-ascription/README.md) | Resolved: ordinary tactic type errors have a semantic-failure regression. |
| [BUC-0006: Cold-start failure evidence](cards/BUC-0006-cold-start-daemon-lifecycle/README.md) | Resolved reporting slice: enriched closure failures and retained incidents. |
| [BUC-0008: Feedback report capture](cards/BUC-0008-agent-feedback-card-api/README.md) | Resolved report capture: feedback-report is separate from submission/card writing. |
| [ULC-0005: Pure frontend readiness report](cards/ULC-0005-pure-frontend-readiness-report/README.md) | Superseded by the deferred ULC-0002 readiness question. |

The separate Lean packaging proposal
[#15665](https://github.com/leanprover/lean4/pull/15665) is related upstream work,
not an implementation of these filesystem or subprocess contracts.

## Current review and release boundaries

This index was reconciled against Beam `c716816dbd3ab392279978b5a930536cd4d3df59`.
The review is source and backlog reconciliation, not fresh qualification of every
historical report. Each card states its own evidence revision and missing tests.

- ULC-0003 and ULC-0004 now include the diagnostic API acceptance requirements
  identified during the review of [#369](https://github.com/leanprover/lean-beam/pull/369).
  Its Beam-only duplicate removal does not depend on either upstream patch.
- ULC-0010's Windows migration already uses the retained child handle in Beam;
  its non-consuming POSIX observation request remains open.
- ULC-0016 records the retained-import contract referenced by
  [#370](https://github.com/leanprover/lean-beam/issues/370). The related
  [#368](https://github.com/leanprover/lean-beam/pull/368) implementation remains
  proposed until merged and qualified.
- The resolved BUC cards close only their stated reporting or behavior slices.
  They do not close unrelated worker-death, startup-timeout or cancellation work.

Card status and release priority are different decisions. The GitHub milestones
own release assignments; a deferred problem is still live. In particular,
[#339](https://github.com/leanprover/lean-beam/issues/339),
[#331](https://github.com/leanprover/lean-beam/issues/331), and
[#256](https://github.com/leanprover/lean-beam/issues/256) remain deferred to 0.3.0.
This refresh does not add upstream patches as 0.2.0 release prerequisites.

## Migration and ownership

The Beam integration coordinator owns this backlog and its consolidation PR.
The coordinator owns the next triage and ownership decision. An upstream
implementer is unassigned unless a card explicitly names one; backlog
ownership does not assign work to an upstream maintainer. Before pursuing a card,
record who owns its next reproduction, design discussion, or patch.

For upstream APIs, record the first version providing the complete required
contract. Then review a separate migration against the admitted targets in
[Compatibility Policy](../COMPATIBILITY.md), using its live release registry
and named nightly target. This backlog does not raise that floor.
Do not add runtime version negotiation or permanent parallel fallback strategies.
Delete obsolete native bindings, source/object targets and unused linkage when
their full replacement is available; retain consumer-policy and regression tests.

## Card rules

Record one canonical card per independently removable contract. Keep existing
identifiers when editing or superseding work; do not renumber older reports.
The index is a navigation view, not a second task tracker. Keep reproductions,
implementation ownership, providing versions and removal conditions in the card.

- Use the [template](TEMPLATE.md), or update an existing card for the same problem.
  Keep the index short; detailed evidence and acceptance criteria belong in cards.
- Distinguish source inspection, historical test reports, fresh reproductions,
  proposed behavior and shipped support. Record exact source revisions for API claims.
- Keep one independently removable contract per card. Cross-link a small slice
  and a larger consumer requirement instead of claiming the slice retires everything.
- Keep `candidate` work separate from `open` work with a bounded upstream ask.
  Mark deliberate postponements `deferred`, replacements `superseded`, and completed
  decisions `resolved`. Retain identifiers and reasons when closing work.
- Search existing issues/PRs and link them before preparing another proposal.
  A card is not authorization to post an upstream issue or PR.
- Keep raw downstream source, traces, local paths and unsanitized logs out of this
  public backlog. Link public reduced examples or describe the missing evidence.
- When support lands, update the card with the providing version and actual Beam
  deletion before marking the migration resolved.

The short index, individual evidence cards and explicit removal targets follow
[Verso Blueprint's collaboration-card approach](https://github.com/leanprover/verso-blueprint/pull/424).
