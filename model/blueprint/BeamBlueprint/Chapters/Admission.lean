import Verso
import VersoManual
import VersoBlueprint
import BeamModel

open Verso.Genre
open Verso.Genre.Manual
open Informal

#doc (Manual) "Who may touch the document?" =>
%%%
tag := "guide-admission"
%%%

A closing flag rejects work that arrives while closure is in progress. It cannot
reject a source read that started earlier, paused, and resumes after the flag is
removed. That delayed read is the reason for admission capabilities and fencing.
Beam captures a {deftech}[permit], a scoped capability to seek document admission,
before asynchronous source work.

:::group "document-admission"
Document admission and exclusive closure.
:::

:::definition "closing-state" (parent := "document-admission") (lean := "BeamModel.Closing.State")
*Abstract specification.* One document slot contains an owner identity, an
admission {deftech}[fence] that invalidates older read permissions, a source basis,
and either an open document or a closing lease.
An {deftech}[owner] identifies the enclosing lifetime. A {deftech}[basis]
identifies accepted source within that lifetime. A {deftech}[lease] identifies
one close attempt; even unchanged source does not make two attempts the same.
:::

:::definition "closing-reservation" (parent := "document-admission") (lean := "BeamModel.Closing.reserve") (uses := "closing-state")
Accept source and reserve closure in one transition. Advance the fence and return
a lease containing the accepted document and current owner. Conflicting admission
cannot occur between acceptance and reservation in this specification.
:::

# Trace: a delayed read
%%%
tag := "guide-delayed-read"
%%%

1. Request A captures permission to read under fence 7, then pauses.
2. Close-save B accepts source and reserves closure, advancing the fence to 8.
3. B fails during preparation and releases its own scope. The document stays open.
4. A resumes. Its old permission remains invalid. A fresh request may retry.

Fencing survives failure intentionally. This conservative ordering avoids reviving
old work when a reservation is released. It is a policy, not a theorem that every
possible close-save interface must behave this way.

:::definition "admission-state" (parent := "document-admission") (lean := "Beam.Broker.DocumentAdmission.State")
*Production component.* The broker stores in-flight permits and their phases,
with a monotone allocation counter. Reserving a URI revokes competing permits for
that URI. Releasing a scope removes its entry. The implementation does not need a
permanent fence record for every closed path.
:::

:::theorem "admission-fence-survives-release" (parent := "document-admission") (lean := "BeamModel.Admission.reserve_release_rejects_same_uri") (uses := "admission-state")
*Direct production law.* After a successful reservation and matching release,
every same-URI permit checked in the resulting state is stale. Release does not
revive a permission invalidated by the reservation.
:::

:::proof "admission-fence-survives-release"
The proof unfolds reservation, which fences the URI, and applies the law that
fencing followed by release still rejects same-URI permits. It concerns the real
pure component, while the broker's capture-before-read ordering remains an
adapter obligation.
:::

:::theorem "admission-exact-cleanup" (parent := "document-admission") (lean := "BeamModel.Admission.release_preserves_other_entry") (uses := "admission-state")
*Direct production law.* Releasing one permit preserves every entry with a
different permit. Late cleanup from attempt A cannot release attempt B's entry.
:::

:::proof "admission-exact-cleanup"
Release filters by exact permit identity. Membership of a different permit is
unchanged by that filter. The surrounding runtime must also check the captured
workspace lifetime; a local permit number alone is not a global identity.
:::

:::theorem "admission-retirement" (parent := "document-admission") (lean := "BeamModel.Admission.retire_rejects_permit") (uses := "admission-state")
*Direct production law.* Retirement makes all permits stale. It does not
establish that remote computation has stopped.
:::

# What the broker must still do
%%%
tag := "guide-admission-adapter"
%%%

Capture the permit before asynchronous source work. Accept source and reserve
closure under the same state transition. Retain the captured owner across waits.
Release only that scope in cleanup. The pure laws do not prove those call sites
are correctly ordered; deterministic regression schedules check that boundary.
The abstract {bpref "closing-reservation"}[] explains the contract, but a complete
refinement from the broker to that specification has not been proved.
