-- Every proof in this first section is complete. Intermediate tactics leave goals for the next
-- tactic, which todo must not report as incomplete proofs.

theorem progressRewrite (n : Nat) (h : 0 < n) : 0 < n + n := by
  rw [Nat.add_comm]; omega

theorem progressRewriteLines (n : Nat) (h : 0 < n) : 0 < n + n := by
  rw [Nat.add_comm]
  omega

theorem progressSkip (n : Nat) (h : 0 < n) : 0 < n + n := by
  skip; omega

theorem progressCombinator (p q : Prop) (hp : p) (hq : q) : p ∧ q := by
  constructor <;> assumption

theorem progressCases (p q : Prop) (hp : p) (hq : q) : p ∧ q := by
  constructor
  case left => exact hp
  case right => exact hq

theorem progressUnification (p : Prop) (hp : p) : p ∧ p := by
  refine ⟨?a, ?b⟩
  all_goals exact hp

theorem progressConv (a b : Nat) (h : a = b) : a + 0 = b := by
  conv => lhs; rw [Nat.add_zero]
  exact h

theorem progressTerm : True ∧ True := ⟨by trivial, by skip; trivial⟩

-- Each proof below leaves exactly one goal open at the end of a `skip`.

theorem progressOpenBullet : True ∧ True := by
  constructor
  · trivial
  · skip

theorem progressOpenAlternative (n : Nat) : n + 0 = n := by
  induction n with
  | zero => rfl
  | succ n ih => skip

theorem progressOpenTerm : True ∧ True := ⟨by trivial, by skip⟩
