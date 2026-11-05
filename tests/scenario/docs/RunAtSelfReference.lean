theorem earlierFact : True := trivial

theorem tacticSelf : False := by sorry

theorem termSelf : False := sorry

def holeSelf : Nat := _

def countDown : Nat → Nat
  | 0 => 0
  | n + 1 => by exact countDown n

theorem laterFact : True := trivial

mutual
  theorem mutualLeft : False := by sorry
  theorem mutualRight : False := by sorry
end
