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

Start with the example and model boundaries, then follow the chapters in order.
The graph is a guide to selected definitions and laws, not an end-to-end broker
verification claim. Definition and theorem previews use the repository's actual
Lean sources; no copies of model code are maintained here.

{include 0 BeamBlueprint.Chapters.Orientation}
{include 0 BeamBlueprint.Chapters.Admission}
{include 0 BeamBlueprint.Chapters.Publication}
{include 0 BeamBlueprint.Chapters.Protocol}
{include 0 BeamBlueprint.Chapters.Settlement}
{include 0 BeamBlueprint.Chapters.Connections}

{blueprint_graph (pack := true)}
{blueprint_summary}
