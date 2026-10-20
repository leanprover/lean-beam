import BeamTest.LSP.Requests.RunAt.SuggestionSupport

-- Multibyte document text: éα😀
theorem suggestionGoalUnicode : True := by
  trivial -- probe

#check Nat -- command
