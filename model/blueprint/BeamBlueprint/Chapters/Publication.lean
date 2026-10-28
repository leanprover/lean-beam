import Verso
import VersoManual
import VersoBlueprint
import BeamModel

open Verso.Genre
open Verso.Genre.Manual
open Informal

#doc (Manual) "Who may publish a checkpoint?" =>

Private preparation and canonical publication are separate responsibilities.
A worker may finish late without being allowed to replace the checkpoint. This
separation makes abandonment safe without promising immediate cancellation.

:::group "checkpoint-authority"
Private preparation, publication authority, and known commits.
:::

:::definition "publication-state" (parent := "checkpoint-authority") (lean := "BeamModel.Publication.State")
*Abstract specification.* One attempt is preparing, ready, committed, or
abandoned. It records worker and trace completion, a `current` ownership predicate,
private-write count, and canonical-commit count. Distinct attempts are assumed to
have disjoint private destinations. `current` stands for real identity and source
checks; the Boolean itself does not prove those checks correct.
:::

:::definition "publication-step" (parent := "checkpoint-authority") (lean := "BeamModel.Publication.step") (uses := "publication-state")
Worker completion precedes trace readiness. Promotion requires a ready, current
attempt. Abandonment removes authority permanently, although private writes may
continue. An already committed attempt retains its commit when abandoned.
:::

:::theorem "publication-abandonment" (parent := "checkpoint-authority") (lean := "BeamModel.Publication.abandoned_run") (uses := "publication-step")
*Abstract law.* Every finite continuation from an abandoned attempt remains
abandoned and preserves its canonical-commit count. Late private completion
cannot regain publication authority.
:::

:::proof "publication-abandonment"
Each transition preserves abandonment and its commit count. Induction over the
remaining trace lifts this one-step fact to every finite continuation.
:::

# Trace: cancellation while Lean is writing

1. The worker writes only this attempt's private files.
2. The caller requests cancellation. This is a soft signal, not evidence that
   the producer stopped.
3. During ordinary cooperative cancellation, Beam waits for private completion,
   then declines publication and disposes acknowledged private files.
4. Genuine channel loss can instead leave producer completion uncertain. The
   attempt loses publication authority; its private files may have to remain.

This is the reason that harmless late private writes need not retire a healthy
shared backend. It is also why cancellation and safe file deletion are different
questions. The specification proves the authority rule, not eventual cleanup.

# Where the atomic abstraction stops

The model has one atomic promotion step. Production has a publication claim,
multiple filesystem operations, possible recovery, and release of that claim.
The runtime must validate identity, source basis, and cancellation, install the
claim, then perform the effects. Affected owner changes wait for the claim.
The current model does not prove atomic visibility of the artifact family,
crash recovery, or exclusion of independent Lake/Beam writers. Nor does trace
completion prove that the worker loaded the dependency artifacts described by that
trace. Imported-artifact provenance is a separate implementation obligation.

:::theorem "closing-known-commit" (parent := "checkpoint-authority") (lean := "BeamModel.Closing.run_preserves_commit") (uses := "closing-state")
*Abstract law.* Once a checkpoint receipt is observed, every finite sequence of
closing-model transitions preserves that observation, even if the owner is lost.
:::

:::proof "closing-known-commit"
Every transition preserves existing receipt membership; induction extends the
property to a trace. Observing a commit is an input fact, not permission to publish.
:::

A real commit, the broker knowing it committed, acceptance of an output frame,
and the client receiving the response are four different milestones.
{bpref "closing-known-commit"}[] addresses preservation of known evidence. It
neither discovers unacknowledged commits nor supplies a durable receipt journal.
