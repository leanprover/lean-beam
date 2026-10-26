universe u

namespace Hidden
def val : Nat := 8
end Hidden

section
open Hidden
local notation "MAGIC" => (8 : Nat)

def letHole (n : Nat) : Nat := let k := n + 1; _
def letIHole : Nat := letI : Inhabited Nat := ⟨42⟩; _
def instHole (α : Type) [Inhabited α] : α := _
def openHole : Nat := _
def notationHole : Nat := _
def universeHole (α : Type u) (a : α) : α := _
theorem unusedUniverse : True := sorry
theorem headerUniverse.{v} (α : Type v) : True := sorry
end

theorem termSelf : False := sorry
theorem tacticSelf : False := by sorry
