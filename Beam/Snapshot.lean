/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

namespace Beam

/-- A broker-owned source snapshot. Clients round-trip its opaque string representation. -/
structure SnapshotRef where
  session : String
  revision : Nat
  deriving Inhabited, BEq, Repr

namespace SnapshotRef

def encode (snapshot : SnapshotRef) : String :=
  s!"{snapshot.session}/{snapshot.revision}"

def decode (text : String) : Except String SnapshotRef := do
  match text.splitOn "/" with
  | [session, revisionText] =>
      unless !session.isEmpty do
        throw "snapshot must be an opaque token returned by update or sync"
      let some revision := revisionText.toNat?
        | throw "snapshot must be an opaque token returned by update or sync"
      unless revision > 0 && toString revision == revisionText do
        throw "snapshot must be an opaque token returned by update or sync"
      pure { session, revision }
  | _ => throw "snapshot must be an opaque token returned by update or sync"

end SnapshotRef

instance : ToString SnapshotRef := ⟨SnapshotRef.encode⟩
instance : Lean.ToJson SnapshotRef := ⟨fun snapshot => Lean.toJson snapshot.encode⟩
instance : Lean.FromJson SnapshotRef := ⟨fun json => do
  SnapshotRef.decode (← json.getStr?)⟩

end Beam
