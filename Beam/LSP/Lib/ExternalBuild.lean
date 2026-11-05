/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

namespace Beam

/--
The one sentence every message suggesting an external Lake build must end with. The file worker and
the broker both produce such messages, so it lives here with no dependencies. A build while the
session is live leaves Beam's sync and save history describing artifacts that changed under it.
-/
def externalLakeBuildProcedure : String :=
  "To build with Lake instead, first stop the CLI owner or drop the MCP workspace and confirm " ++
    "cleanup; rebuild only after cleanup completes, then start a fresh session or workspace."

end Beam
