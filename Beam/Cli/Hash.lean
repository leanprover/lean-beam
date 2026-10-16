/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

namespace Beam.Cli

def hashByte (acc : UInt64) (byte : UInt8) : UInt64 :=
  (acc ^^^ byte.toUInt64) * 1099511628211

def hashBytes (bytes : ByteArray) (init : UInt64 := 14695981039346656037) : UInt64 :=
  bytes.foldl hashByte init

def hashString (text : String) (init : UInt64 := 14695981039346656037) : UInt64 :=
  hashBytes text.toUTF8 init

def mixField (acc : UInt64) (text : String) : UInt64 :=
  hashString text <| hashByte acc 0

end Beam.Cli
