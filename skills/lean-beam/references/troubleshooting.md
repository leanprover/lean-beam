# Troubleshooting

Read this only when a Beam call fails, stalls, or behaves unexpectedly. Start with the matching
symptom; read only that section and do not run every diagnostic or recovery command. Keep the
original request's owner responsible until its outcome and any cleanup are established.

Error paths use CLI notation (`error.data`). MCP tool failures expose the same fields under
`structuredContent.data` with `isError: true`; JSON-RPC transport errors have a separate envelope.

| Symptom | Start here |
|---|---|
| Tool call pending, unexpected approval, or no MCP progress | [Client approval and stalled calls](#client-approval-and-stalled-calls) |
| Startup, toolchain selection, or runtime identity looks wrong | [Setup and identity](#setup-and-identity) |
| CLI cannot reach a live owner | [CLI transport and session recovery](#cli-transport-and-session-recovery) |
| `contentModified`, sync barrier, save refusal, or uncertain checkpoint | [Sync and save failures](#sync-and-save-failures) |
| `workerCrashed` or `workerExited` | [Worker recovery](#worker-recovery) |
| Corrupted installation or install-root marker | [Installation recovery](#installation-recovery) |

## Client Approval And Stalled Calls

An MCP client can pause a tool call for user approval or automatic review before dispatching it.
Beam cannot report progress for a request it has not received. A pending call, an execution-cell
ID, or silence from Beam does not establish that Lean is running or stuck.

1. Inspect the calling task and its parent for a pending approval, review, or permission prompt.
   Record the exact tool, arguments, task, request/item ID, and whether a decision is outstanding.
   A task-wide `waitingOnApproval` flag alone does not identify the pending action.
2. Surface that specific pending action to its owner/operator through the client's approval UI.
   Existing authorization for the work does not prove the client received an approval decision.
   If the client exposes no prompt or request ID, report that visibility gap with the task/call
   identities; do not guess or approve a different action.
3. Preserve the original call while awaiting its outcome. Do not issue an overlapping retry,
   refresh, workspace drop, server restart, or larger workload to test whether it is alive. A wait
   budget expiring is an observation, not cancellation or proof of producer settlement.
4. If the call settles with an error or denial, preserve the structured result before choosing
   recovery. If it succeeds, use its actual returned document version. When approval is resolved
   but the call remains pending, record the last observed boundary: client dispatch, server
   acceptance, response, or caller receipt. Mark unavailable observations as unknown.

Beam's effect annotations describe the tools' behavior; they do not grant permission. In particular,
`lean_sync` updates tracked document state. Do not relabel it read-only or disable approval policy
as a troubleshooting shortcut. Client policy changes belong to the operator and should match the
specific tool and intended effects. A shell fallback may use a different owner or permissions and
does not establish what happened to the original MCP call.

For Codex, the [official approval documentation](https://learn.chatgpt.com/docs/app-server#mcp-tool-call-approvals-apps)
describes MCP/app approval gates. The
[configuration reference](https://developers.openai.com/codex/config-reference/)
documents per-tool MCP approval overrides. These describe client capabilities, not Beam recovery
commands or guarantees that a pending approval is visible to every agent.

## Setup And Identity

Choose the diagnostic for the question; these identities are not interchangeable:

- `lean-beam --version`: CLI installed runtime identity.
- `lean-beam-mcp --version`: which wrapper, server binary, payload, manifest, and source commit a
  newly launched MCP command resolves.
- MCP `beam_version`: the running server's retained installation identity. Coordinate with the
  owner of a pending call before sending diagnostic MCP calls; a second successful call does not
  prove the first one settled.
- `lean-beam doctor`: selected installation, toolchain support, target membership, and session state.
- `lean-beam doctor clients CLIENT --verbose`: supported static client configuration checks.
  This does not inspect the running client's approval UI, effective managed policy, or loaded tools.

Changing an installation's `current` link does not retarget a running server. A missing runtime
target needs explicit installation, not repeated probes or borrowed components. Follow
[setup and toolchain selection](setup-and-recovery.md) when configuration actually needs changing.

## CLI Transport And Session Recovery

A healthy CLI owner can be unreachable when owner and client commands use different network
namespaces. Check [sandbox permissions](setup-and-recovery.md#sandbox-permissions) first. MCP stdio
does not use the CLI loopback connection; a CLI failure is not evidence of an MCP transport failure.

For a completed CLI failure, inspect its structured code and `error.data`. Exit `2` means local
usage/input error; exit `3` (`noLiveSession`) includes the exact `serve` remedy; exit `130`
(`requestCancelled`) reports interruption without establishing producer settlement. Local remedies
are `{executable, arguments}` objects in `error.data.remedy_command`; conditional recovery uses
`recovery_command` with the same shape. After confirming the intended action and its prerequisites,
execute the exact vector with shell parsing disabled. Stderr contains a human display, using POSIX
syntax on Linux/macOS and PowerShell on Windows; do not parse or execute that display.

- `sessionRecoveryRequired` (exit `1`) includes the generation when known. Obey its
  `recovery_precondition` and independently verify that the matching owner, daemon, and all other
  producers stopped before recovery. Connection refusal and an unavailable endpoint are insufficient.
- `status` state `unresponsive` means the endpoint did not validate, including incomplete or
  malformed replies. `sessionUnresponsive` (exit `1`) preserves the descriptor and refuses recovery.
  Inspect the original owner and daemon through their supervisor before retrying.
- `serve` checks the selected descriptor locally without probing its endpoint. An existing
  matching-root descriptor marked `live` fails with `setupError`, configuration hashes, and an exact
  `status` remedy. This does not establish owner liveness. `status` state `running` means an
  authenticated workspace probe succeeded, not that Lean elaboration finished.
- The first successful `stop` acknowledges shutdown with `state: "stopping"`. A retained shutdown
  descriptor means completion is unconfirmed: `status` reports `shutdownUnconfirmed`; repeated stop,
  serve, or attachment gives `sessionShutdownUnconfirmed` with the generation and owning-installation
  `status` remedy. Wait for cleanup and check for `absent` before restarting.
- Execute `remedy_command.executable` with its exact `arguments`; a different installation on
  `PATH` cannot control this session (`sessionInstallationMismatch`). If the owning executable is missing,
  coordinate with the original owner or supervisor.
- A mismatched recovery generation returns `invalidParams`/exit `2` with the recorded generation.
  Do not substitute that ID and retry automatically. Confirm the intended generation and independently
  verify that every original producer stopped. Neither a descriptor nor its age proves owner death.

Interrupting the owner or running `stop` requests shutdown; it does not establish completed
cleanup or an overall shutdown deadline. After an abnormal owner or broker exit, the session can
remain fenced. Once shutdown is confirmed, use the original installation, root, and session
selection with `recover --generation ID` for the intended generation; recovery quarantines metadata and never signals
its recorded PIDs. `recovery_command` is a separate conditional command: if cleanup cannot finish
within the caller's waiting budget, perform full supervised cleanup before recovering any remaining
descriptor. The full
[session recovery contract](https://github.com/leanprover/lean-beam/blob/main/docs/SETUP.md#sessions-and-recovery)
describes owning-installation commands and shutdown states.

## Sync And Save Failures

Inspect typed failure codes and `error.data`; do not parse rendered exception text to decide recovery.
If the request remains pending, return to [stalled calls](#client-approval-and-stalled-calls).

- On `contentModified` with `reason = "documentVersionMismatch"`, use
  `error.data.accepted_version` or run `update` again. Never guess a version.
- On `contentModified` with `reason = "documentClosing"`, coordinate with the close-save caller;
  do not run an update/sync retry loop. Same-workspace changes wait during claimed publication.
- On `contentModified` with `reason = "documentAdmissionExpired"`, closure or backend replacement
  invalidated the request. After coordination, issue a new request and reacquire handles if the
  backend was replaced.
- On `syncBarrierIncomplete`, save the listed `error.data.save_deps`, then refresh
  `error.data.target_path` in the same CLI session or MCP workspace. Stop on a missing plan or
  failed step. Inspect diagnostics/readiness after successful refresh; if still blocked, stop
  retries and inspect upstream diagnostics/configuration. See the
  [readiness recovery contract](workflow-details.md#file-progress-and-readiness). A failed sync
  is not save-ready.
- On `saveImportsChanged`, refresh, then save.
- On `saveUnsupportedSetup` caused by batch-only `moreLeanArgs`, move shared `-D` settings to
  `leanOptions`. When those arguments are intentionally batch-only, use the
  [external build procedure](workflow-details.md#before-a-local-batch-build), including confirmed
  Beam cleanup before building.
- On `error.data.reason = "savedDocumentChanged"`, `error.data.saved` records an already committed
  checkpoint of an earlier version. Run `update` or `sync` and save again if needed. Other postcommit
  failures also retain `error.data.saved`, with prior data under `error.data.original_data`. An
  uncertain close does not assert `closed = false`; cancellation cannot undo a committed checkpoint.

If stale-state or rebuild errors keep recurring, inspect `open-files` and `doctor`, then stop and
report the problem. Do not turn recovery into a retry loop.

## Worker Recovery

On `workerCrashed` or `workerExited`, use `lean-beam sync PATH` (MCP: `lean_sync`) to reopen the
affected file and wait for readiness before further probes. A fresh `save` or `close-save` also
recovers during its initial synchronization. Reopening invalidates that worker's old handles and
elaborates saved source again; source-level effects can run again.

If a settled request indicates worker trouble without a typed exit, explicit
`lean-beam refresh PATH` (MCP: `lean_refresh`) resets the tracked document. Check pending-call
ownership first: elapsed time or generic fatal progress alone does not establish worker exit.
An unresolved close-save still owns its file; cooperative cancellation does not establish
settlement. Coordinate recovery of the owning session/runtime when needed. See the
[worker recovery contract](https://github.com/leanprover/lean-beam/blob/main/docs/SYNC_AND_DIAGNOSTICS.md#worker-errors-and-document-recovery).

## Installation Recovery

If a runtime's own manifest is corrupted or replaced, identity reporting fails. Stop normal Beam
work and preserve the installation for inspection. Do not repair it with `prune`. After stopping
active Beam agents and MCP clients, move the invalid runtime out of `BEAM_INSTALL_ROOT/versions`,
keep it for inspection, and rerun the installer.

For an invalid install-root marker, preserve and rename the whole `BEAM_INSTALL_ROOT` before
reinstalling. Do not recreate the ownership marker in place or delete the preserved state.

`lean-beam prune` previews old installed runtimes. Before `prune --apply`, stop old owners and
confirm cleanup, update clients pinned to old executables, and verify the running server's
intended installation with `beam_version` for each MCP server in use. Preview and apply each
compute a fresh plan. Coordinate installers and other maintenance so no other process changes
the installed generations or `current` selection before apply completes. If that state changes,
preview again and repeat the usage checks. Do not apply while any removal candidate is in use,
and coordinate clients so none starts using a candidate before apply completes.

## Reporting An Unresolved Problem

Record the transport (CLI or MCP), workspace, exact tool/command and arguments, structured outcome
or pending status, caller/request identities, timestamps, and the last confirmed boundary. Include
runtime identity only if already known or safely obtainable; do not start another call solely to
fill a report while the original is pending. Avoid attributing a client approval wait to a Lean
worker without server evidence.

While a call is pending, draft the report locally without invoking another Beam tool. After
settlement, use [feedback reports](feedback.md) for the report schema, optional local bundles, and
confidentiality rules. Review paths, source snippets, and payloads before sharing; Beam never
submits the report.
