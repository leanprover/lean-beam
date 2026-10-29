import Verso
import VersoManual
import VersoBlueprint
import VersoBlueprint.Commands.Graph
import VersoBlueprint.Commands.Summary
import BeamBlueprint.Chapters.Orientation
import BeamBlueprint.Chapters.Admission
import BeamBlueprint.Chapters.Publication
import BeamBlueprint.Chapters.Protocol
import BeamBlueprint.Chapters.Settlement
import BeamBlueprint.Chapters.Connections

open Verso.Genre
open Verso.Genre.Manual
open Informal

#doc (Manual) "Understanding Beam's ownership models" =>

Beam must preserve ownership when source reads are delayed, workers fail, or
responses arrive after a caller has cancelled. This guide explains the small
models used to reason about those boundaries and where their proofs stop.

* *First reading:* start with the {ref "guide-example"}[close-save example] and
  {ref "guide-model-map"}[model map], then follow admission and publication.
* *Protocol and failure handling:* read about the {ref "guide-peer-crash"}[crashed
  peer] and {ref "guide-competing-handlers"}[competing request handlers].
* *Reviewing a proof claim:* use the {ref "guide-evidence"}[evidence levels] and
  {ref "guide-trusted-boundaries"}[remaining runtime obligations].

The graph provides focused views and previews of existing Lean declarations.
This is a guide to selected definitions and laws, not an end-to-end broker
verification claim. The prose links help navigation; only mathematical
dependencies appear as graph edges.

{include 0 BeamBlueprint.Chapters.Orientation}
{include 0 BeamBlueprint.Chapters.Admission}
{include 0 BeamBlueprint.Chapters.Publication}
{include 0 BeamBlueprint.Chapters.Protocol}
{include 0 BeamBlueprint.Chapters.Settlement}
{include 0 BeamBlueprint.Chapters.Connections}

{blueprint_graph (pack := true)}
{blueprint_summary}
