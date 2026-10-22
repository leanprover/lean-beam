example (a b : Nat) (h : a = b) : 0 + a = b := by
  simp
  exact h
example : ∀ a b : Nat, a + b = b + a := by
  intro a b
  omega
