-- Common mistakes an agent leaves in a proof. `todo` must report one item for each problem, carry
-- the goal that `runAt` sees at the item's position, and drop Lean diagnostics that only restate
-- an item. `BeamTest.Fixtures.TodoFixture.agentItems` lists the expected items.

theorem bulletSorry : True ∧ True := by
  constructor
  · trivial
  · sorry

theorem failedExact (n : Nat) : n + 0 = n := by
  exact Nat.foo n

theorem failedDecide : 2 + 2 = 5 := by
  decide

theorem failedOmega (n : Nat) : n * n ≥ n + 1 := by
  omega

theorem haveSorry (n : Nat) : n = n := by
  have h : n + 0 = n := sorry
  rfl

theorem stopsEarly : ∀ n : Nat, n = n := by
  intro n

theorem calcSorry (a b : Nat) (h : a = b) : a + 0 = b := by
  calc a + 0 = a := by simp
    _ = b := sorry

theorem openAlternative (n : Nat) : 0 + n = n := by
  induction n with
  | zero => rfl
  | succ n ih => skip

theorem refineHoles : ∃ n : Nat, n = 3 := by
  refine ⟨?_, ?_⟩

theorem solvedHole : ∃ n : Nat, n = 3 := ⟨_, rfl⟩

def termHole (xs : List Nat) : Nat := xs.length + _

theorem termSorry (p q : Prop) (hp : p) (hq : q) : p ∧ q := ⟨hp, sorry⟩

theorem unusedHypothesis (n : Nat) (h : n = 1) : True := by
  trivial

theorem complete (a b : Nat) : a + b = b + a := by
  rw [Nat.add_comm]

theorem refineThenSorry (h : ∃ n : Nat, n > 3 ∧ n < 5) : ∃ m : Nat, m = 4 := by
  obtain ⟨k, hk1, hk2⟩ := h
  refine ⟨k, ?_⟩
  sorry

theorem exactWithHole (p q : Prop) (hp : p) (hq : q) : p ∧ q := by
  exact ⟨hp, _⟩
