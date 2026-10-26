theorem termSorry (p q : Prop) (hp : p) (hq : q) : p ∧ q := ⟨hp, sorry⟩

def termHole (xs : List Nat) : Nat := xs.length + _

theorem solvedHole : ∃ n : Nat, n = 3 := ⟨_, rfl⟩

theorem nestedSorry (n : Nat) (h : 0 < n) : n ≠ 0 := by
  exact Nat.pos_iff_ne_zero.mp sorry

def instanceHole {α : Type} [Inhabited α] (xs : List α) : α := xs.headD _

theorem namedHole (p : Prop) (hp : p) : p ∧ True := ⟨?x, trivial⟩
