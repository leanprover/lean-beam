# MCP stdio transport contract

[MCP.md](MCP.md) describes public protocol behavior. This contract defines ownership and resource
limits for the stdio transport. The broker owns execution and cleanup; the transport owns delivery.
Lake text-buffer integration is a separate follow-up.

## 1. One writer owns stdout

The input reader, workers, and reporters hand complete JSON-RPC messages to one writer. They never
write stdout directly. Messages cannot interleave. Retained diagnostic notifications precede their
request's final response; ordinary responses may arrive out of request order.

Output storage is bounded. Before accepting work, reserve space for a small terminal error.
A successful result may claim additional shared storage when it finishes. If its encoded frame is
too large or shared storage is full, send a request-specific output-limit error using the reserved
space. The error must explain that the operation may already have completed. It must not cause
unrelated requests or workspaces to be cancelled.

Keep errors typed through the output boundary. Encoded-size preflight includes UTF-8, JSON escaping,
envelope metadata, the newline, and retained trace labels. Use Lean's JSON serializer after that
check; never truncate a final response.

## 2. Execution admission and delivery have different lifetimes

Execution admission limits unfinished work, including work queued behind workspace-control fences.
Release that admission after operation and resource cleanup, before waiting for response delivery.
A pending reply retains message data and an exact private identity, but no broker handle, document
permit, publication authority, or callback that can execute broker work.

Retire the matching external JSON-RPC ID when committing the terminal outcome, before the response
becomes visible. Late producers and completions refer to the private admission, so they cannot
alter another request that reuses the same external ID. A write attempt is not client acknowledgement.

Cancellation before terminal acceptance suppresses the response while execution cleanup continues.
Cancellation afterward leaves the accepted response unchanged. Cancelled execution retains its
small output reservation until cleanup finishes. A queued workspace eviction may be cancelled;
a started eviction is protected from client cancellation and retains a truthful outcome.

## 3. Ordinary overload stays local

If execution admission or normal output reservations are unavailable, reject the incoming request
with a JSON-RPC busy error before beginning work. Busy replies and unowned protocol errors use a
separate bounded reserve. When that reserve is also full, pause input until delivery frees space.
Wait outside coordinator locks; admitted workers and the writer keep running.

Complete saturation therefore delays reading later cancellation notifications and observing EOF.
This is deliberate input backpressure, not a session failure. Once output drains, input resumes.
The transport cannot guarantee unlimited correlated replies, finite storage, and uninterrupted
input processing when a client sends indefinitely without reading.

Diagnostic and status log notifications retain a bounded prefix. Once their pending byte/record
budget or the shared storage budget is exceeded, count subsequent omissions without stalling the
request. The final result reports the count in
`result._meta["lean-beam/output"].diagnosticsOmitted`; JSON-RPC errors use
`error.data["lean-beam/output"].diagnosticsOmitted`. Existing result metadata and error data survive.
Progress has one replaceable pending notification per request. Oversized progress is discarded;
terminal acceptance removes obsolete progress. Omitted/replaced progress is not counted as a lost
log notification.

The internal limits are not client settings:

| Resource | Limit |
| --- | --- |
| Unfinished execution admissions | 32 |
| Shared normal output storage, including reservations and notifications | 64 MiB |
| Separate rejection/protocol-error reserve | 256 KiB |
| Small terminal reply reserved per admission | 4 KiB |
| Encoded successful response | 8 MiB |
| Pending diagnostic/status logs per request | 256 KiB and 64 records |
| Replaceable progress per request | One notification, at most 64 KiB |

The rejection reserve holds up to 64 small replies. Normal output reservations are bounded by the
shared byte budget, independently of the execution limit. One physical frame may additionally be
in flight. These bounds cover transport-owned frames and reservations, not input decoding, result
construction, object overhead, or broker computation. An envelope whose ID cannot fit even its
reserved error reply is unrepresentable within these transport limits.

## 4. Observed shutdown starts cleanup before joining execution

Once the reader observes EOF, stop admission and mark cooperative requests cancelled before waking
queued work. Start backend teardown before joining execution: backend closure may itself release
a request. Live workspace-control fences include terminal delivery; after shutdown begins they
wait only for execution cleanup. Started evictions must preserve committed outcomes, and detached
cleanup must not hold the mutex needed to close other workspaces.

Accepted replies may drain while backend cleanup proceeds. A physical write failure or internal
transport fault instead closes the session and starts cleanup independently of the writer. Ordinary
admission, result-size, and diagnostic limits do not take this fatal path.

Synchronous stdout writes can remain blocked while an unread pipe stays open. There is no fixed
process-exit deadline. Complete rejection-reserve saturation can also delay observing stdin EOF,
as described above. Neither limitation allows output waits under broker or coordinator locks.

## Verification

The existing `BeamTest.Broker.McpOutputTest` and `McpRuntimeLifetimeTest` fixtures check storage
accounting, reserved errors, rejection backpressure and resumption, execution/delivery separation,
exact-generation cancellation, and first-failure settlement. They run through the existing MCP
protocol test executable in `bash tests/test-beam-fast.sh`.

`python3 tests/test-mcp-stdio.py --iterations 1 --restart-cycles 1 --timeout 60` checks oversized
results alongside another workspace, 40 gated concurrent calls, 150 diagnostics followed by a
slow reader, and blocked-output EOF cleanup below complete rejection saturation. The existing
slow suite owns longer stdio stress. Platform qualification follows [TESTING.md](TESTING.md).
