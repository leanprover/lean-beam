# MCP stdio transport contract

[MCP.md](MCP.md) describes the public behavior of this transport.
Lake text-buffer integration remains a planned follow-up.

The broker owns execution and cleanup. The transport owns message delivery. A client that stops
reading output must not keep broker resources alive or prevent backend teardown after shutdown
begins. The contract has four rules.

## 1. One writer owns stdout

The input reader, request workers, and progress reporters hand messages to one transport-owned
writer. This includes protocol replies and parse errors. They never write stdout directly or wait
for the client to read. Coordinator locks are released before broker cancellation, cleanup, or
physical output.

The writer serializes complete JSON-RPC messages. Once a message starts, finish it or fail the
transport; messages cannot interleave. Within a request, retained notifications precede the final
response, and none may follow it. Ordinary responses may arrive out of request order.

Output capacity is finite. Reserve one output slot before accepting a request, including one
that only needs a protocol/error reply. If capacity is exhausted or a response exceeds the frame
limit, fail the session and start cleanup rather than block the input reader or truncate a result.
A write error follows the same failure path. Check encoded size before queueing a message.
Failure must reach the session owner independently
of the writer; an explanatory response to the client cannot be guaranteed.

## 2. Finished work releases its resources

Execution is finished when broker effects have completed or are safely contained and the request's
admission and document-reservation cleanup has finished. Operation or cleanup errors remain errors;
an error alone proves neither that effects are contained nor that they are still active.

Accept the final response for delivery only after execution cleanup finishes. Pending output holds
response data and the request's private identity. It holds
no document permit, publication authority, broker handle, or callback that can mutate broker state.
Keep outcomes typed until their existing protocol projection. A lost response cannot undo a
committed save or make its checkpoint receipt false.

Keep execution completion separate from delivery completion. A completed write attempt is not a
client acknowledgement. Match late publishers and completions to the exact internal request,
rather than a reusable external JSON-RPC ID. Retire the matching ID routing entry before its
response becomes visible, so clients can reuse the ID after observing the response.

Cancellation before the response is accepted for delivery discards pending optional output and
suppresses the final response while execution cleanup continues. Cancellation afterward leaves
that accepted response unchanged. A queued workspace eviction may be cancelled; once it acquires
execution ownership after its control fences, it is protected from client cancellation. Make that
ownership transition atomic with cancellation and admission closure. Registration alone is not
execution ownership.

## 3. Progress cannot stall work

Progress updates use one replaceable pending notification per request. Required diagnostics have
a separate budget and retain their order before the final response.

Lake text-output integration is planned. The following helper-buffer requirements are for that
follow-up, not behavior supplied by this transport change. Ephemeral text uses one bounded pending
buffer per request. All helpers for one request share that budget. Retiring one helper's publisher preserves accepted output and the other helpers'
publishers. Helper processes, pipe drains, and temporary files remain owned by the helper scope.
Their cleanup never waits for the client.

For a live request, offering a valid bounded chunk does not wait for capacity. Replace obsolete
progress under its protocol's rules. For text, discard oldest pending chunks when necessary and
attach an omission indication to the next retained chunk. Transfer that indication if its chunk
is later discarded. Updating the buffer and omission indication is atomic.

On normal completion, stop publishing and keep the existing bounded text tail for delivery before
that request's response. Do not truncate it again just because the helper finished quickly.
Remove obsolete pending progress. Cancellation and fatal session failure discard unsent optional
output. An already accepted response keeps its text tail during orderly EOF shutdown.

These helper-buffer rules introduce no transcript files. The transport does not yet consume that
shared text buffer.

Bound retained requests, encoded response size, and pending optional bytes and records per request.
The request limit includes pending delivery, so the per-request budgets also bound aggregate
storage. Count the writer's in-flight message explicitly. Size chunks after UTF-8 encoding, JSON
escaping, and envelope metadata; adapters split text before offering it. Other requests cannot
consume a request's pending-output allowance. Continuing progress must not starve ready responses.

The first implementation uses the following finite limits. These are prototype values to qualify,
not new client settings:

| Resource | Limit |
| --- | --- |
| Retained output slots, including execution and pending delivery | 32 |
| Final response storage per slot | 8 MiB |
| Required diagnostic notifications pending per slot | 256 KiB and 64 records |
| Replaceable progress per slot | One notification, at most 64 KiB |
| Physical output in flight | One frame, at most 8 MiB |

Frame budgets include encoded text and retained diagnostic labels. Required diagnostics are never
replaced by progress or silently discarded: exceeding their budget fails the session. Normal
completion preserves required diagnostics before the response and removes obsolete progress.
These limits reserve final-response space independently of notifications. The conservative bound
for these transport-owned frames is 274 MiB: 32 times the three per-slot byte budgets, plus one
in-flight frame. A future shared text buffer is accounted separately; it must not be copied into
another optional queue.

Reserve the slot before broker admission. Before compressing a JSON envelope, check its encoded
size with a budget-limited traversal, including escaping and metadata, and stop when the budget is
exceeded. Use the existing JSON serializer only after this check. A slow reader leaves messages in
these bounded slots; further admission fails rather than waiting for capacity. Oversized output
also fails the session, without truncating a response or claiming a committed operation failed.
The writer's scheduling algorithm is an implementation choice. These bounds do not bound broker
computation or input-decoding memory.

## 4. Shutdown does not wait for output

On EOF, stop admission, mark cooperative requests cancelled, and stop their publishers before
waking queued work. Start backend teardown before joining outstanding execution: closing the
backend may be what releases a request. Neither the input reader nor the writer must finish first.

Cancel queued workspace evictions too; starting a task or reporting progress does not make an
eviction irreversible. Account for evictions that already acquired execution ownership as teardown
proceeds. Each must finish coherently or have its runtime scope superseded with a truthful outcome. Preserve errors separately from
whether effects are contained; do not declare successful cleanup when containment is unknown.

Accepted responses can continue draining while output remains usable, preserving control fences. Backend cleanup
proceeds independently. Fatal session failure instead discards unsent messages and closes admission
permanently. Broker locks, backend readers, cancellation, and cleanup never wait for output capacity.

A synchronous write may remain blocked while the client leaves an unread pipe open. Moving it to
one writer does not make it interruptible, so this contract gives no fixed process-exit deadline.
See [Lean task cancellation](https://lean-lang.org/doc/reference/latest/IO/Tasks-and-Threads/).

## Scope and verification

Preserve the documented workspace-control ordering and exact broker admissions across waits.
Changing live eviction to wait only for execution is a separate proposal; it is not required to
adopt these ownership rules. Shutdown must still reach teardown independently of those fences.
This contract changes no public request shape and introduces no persistent output storage.

Extend the existing stdio and helper fixtures to check:

- A blocked response followed by a protocol reply or parse error does not prevent EOF observation
  and backend cleanup before output resumes.
- Blocked progress does not prevent cancellation or cleanup.
- A request released only by backend closure does not create a shutdown join cycle.
- A fast helper's accepted text survives until response delivery; a slow reader produces bounded
  pending output with omission indications.
- Responses retain existing ordering, cancellation, request-ID reuse, and committed-save semantics.
- Reliable-output exhaustion and oversized responses fail the session without blocking cleanup or
  producing a truncated result.

Implementation qualification starts with `bash tests/test-beam-fast.sh`, followed by
`python3 tests/test-mcp-stdio.py --iterations 1 --restart-cycles 1 --timeout 60`.
Use the existing slow suite and platform/toolchain checks as required by [TESTING.md](TESTING.md).
These are acceptance criteria, not claims that the proposed behavior has passed them.
