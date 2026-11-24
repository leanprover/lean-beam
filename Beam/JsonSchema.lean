/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam.JsonSchema

/-- JSON Schema revision used by Beam's agent-facing tool schemas. -/
def dialect : String :=
  "https://json-schema.org/draft/2020-12/schema"

def string (description : String) : Json :=
  Json.mkObj [
    ("type", toJson "string"),
    ("description", toJson description)
  ]

def enumString (description : String) (values : Array String) : Json :=
  Json.mkObj [
    ("type", toJson "string"),
    ("description", toJson description),
    ("enum", toJson values)
  ]

def enumStringArray (description : String) (values : Array String) : Json :=
  Json.mkObj [
    ("type", toJson "array"),
    ("description", toJson description),
    ("items", Json.mkObj [
      ("type", toJson "string"),
      ("enum", toJson values)
    ])
  ]

def natural (description : String) : Json :=
  Json.mkObj [
    ("type", toJson "integer"),
    ("minimum", toJson (0 : Nat)),
    ("description", toJson description)
  ]

def bool (description : String) : Json :=
  Json.mkObj [
    ("type", toJson "boolean"),
    ("description", toJson description)
  ]

def object (description : String) : Json :=
  Json.mkObj [
    ("type", toJson "object"),
    ("description", toJson description)
  ]

/--
Construct a closed object input schema for public operation surfaces.

Beam tool inputs are deliberately small and explicit. Keeping `additionalProperties=false` at this
shared boundary prevents operation/MCP decoders from accepting undeclared fields by accident.
-/
def inputObject (properties : List (String × Json)) (required : Array String) : Json :=
  Json.mkObj [
    ("$schema", toJson dialect),
    ("type", toJson "object"),
    ("properties", Json.mkObj properties),
    ("required", toJson required),
    ("additionalProperties", toJson false)
  ]

/-- Reject fields outside the properties advertised by a closed object input schema. -/
def validateInputFields
    (label : String)
    (schema input : Json) : Except String Unit := do
  let properties ← schema.getObjVal? "properties"
  match properties with
  | .obj _ => pure ()
  | other => throw s!"{label} input schema properties must be an object, got {other.compress}"
  match input with
  | .obj fields =>
      let unexpected := fields.foldl (init := #[]) fun unexpected field _ =>
        if (properties.getObjVal? field).isOk then
          unexpected
        else
          unexpected.push field
      unless unexpected.isEmpty do
        throw s!"{label} accepts no undeclared input fields: {String.intercalate ", " unexpected.toList}"
  | other =>
      throw s!"{label} input must be an object, got {other.compress}"

/-- Add one required property to an object schema produced by `inputObject`. -/
def withRequiredProperty
    (schema : Json)
    (name : String)
    (propertySchema : Json) : Except String Json := do
  let properties ← schema.getObjVal? "properties"
  match properties with
  | .obj _ => pure ()
  | other => throw s!"object schema properties must be an object, got {other.compress}"
  let requiredJson ← schema.getObjVal? "required"
  let required ← fromJson? (α := Array String) requiredJson
  let required := if required.contains name then required else required.push name
  pure <| (schema.setObjVal! "properties" (properties.setObjVal! name propertySchema)).setObjVal!
    "required" (toJson required)

end Beam.JsonSchema
