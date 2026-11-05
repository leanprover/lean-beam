import Verso
import VersoManual
import VersoBlueprint
import BeamModel

open Verso.Genre
open Verso.Genre.Manual
open Informal

#doc (Manual) "Who may publish a checkpoint?" =>
%%%
tag := "guide-publication"
%%%

Private preparation and canonical publication are separate responsibilities.
{deftech}[Publication authority] is permission for an attempt to install its
candidates as the canonical checkpoint.
A worker may finish late without being allowed to replace the checkpoint. This
separation makes abandonment safe without promising immediate cancellation.

A {deftech}[build trace] records metadata about checkpoint inputs and outputs.
It differs from an {tech}[event trace], which lists modeled transitions.

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
%%%
tag := "guide-cancelled-preparation"
%%%

1. The worker writes only this attempt's private files.
2. The caller requests cancellation. This is a soft signal, not evidence that
   the producer stopped.
3. During ordinary cooperative cancellation, Beam waits for private completion,
   then declines publication and disposes acknowledged private files.
4. Genuine channel loss can instead leave producer completion uncertain. The
   attempt loses publication authority; its private files may have to remain.

This is the reason that harmless late private writes need not retire a healthy
shared backend. It is also why cancellation and safe file deletion are different
questions. The specification proves the authority rule, not eventual cleanup. The following
checked example runs {InlineLean.name BeamModel.Publication.run}`run` on the
actual model.
Abandonment permits another private write, but late completions and a promotion
attempt leave the canonical commit count at zero.

```InlineLean.lean -keep (name := abandonedPreparation)
open BeamModel.Publication in
#eval
  let s := run {} [.privateWrite, .abandon, .privateWrite,
    .workerComplete, .traceComplete, .promote]
  (s.phase == .abandoned, s.privateWrites,
   s.canonicalCommits)
```

```InlineLean.leanOutput abandonedPreparation
(true, 2, 0)
```

This executable example checks one schedule;
{bpref "publication-abandonment"}[] proves the property for every finite
continuation from an abandoned state.

# Where the atomic abstraction stops
%%%
tag := "guide-publication-boundary"
%%%

The model has one atomic promotion step. Production records a {deftech}[publication claim]: an owned interval during
which the attempt may perform canonical filesystem effects. Recovery and release
finish that interval; affected owner changes wait for it.
The runtime must validate the captured {tech}[owner], source {tech}[basis], and
cancellation, install the claim, then perform the effects.
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
