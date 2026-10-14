/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Init.System.IO

namespace Beam.Mcp.SelfCheck.Pipe

/-- Exclusively owned process pipes only. Do not subsequently use buffered Handle operations. -/
@[extern "lean_beam_pipe_nonblocking"]
opaque nonblocking (handle : @& IO.FS.Handle) : IO Unit

/-- Read at most 8192 bytes: none means would block, some empty means EOF. -/
@[extern "lean_beam_pipe_read"]
opaque read (handle : @& IO.FS.Handle) : IO (Option ByteArray)

/-- Write at most 8192 bytes from offset. Zero means would block. -/
@[extern "lean_beam_pipe_write"]
opaque write (handle : @& IO.FS.Handle) (bytes : @& ByteArray) (offset : USize) : IO USize

end Beam.Mcp.SelfCheck.Pipe
