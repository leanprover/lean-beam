import Lake
open Lake DSL

-- Documentation tooling is pinned separately from Beam's supported runtime toolchains.
require VersoBlueprint from git
  "https://github.com/leanprover/verso-blueprint"@"4943d3335ffa9221a39949e60836a8ad5dc2a456"

package BeamBlueprint where
  precompileModules := false
  leanOptions := #[⟨`experimental.module, true⟩]

-- Compile the real source files; never maintain copies inside the Blueprint.
lean_lib BeamAdmission where
  srcDir := "../.."
  roots := #[`Beam.Broker.DocumentAdmission]

lean_lib BeamModel where
  srcDir := ".."
  roots := #[`BeamModel]

@[default_target]
lean_lib BeamBlueprint where

lean_exe «blueprint-gen» where
  root := `BeamBlueprintMain
