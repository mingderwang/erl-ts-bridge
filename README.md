# Erlang ↔ Bun/TypeScript TCP bridge

A minimal, dependency-free example of a persistent TCP connection between an Erlang/OTP server and a Bun + TypeScript client on different machines.

## Requirements

- Erlang/OTP (`erl` and `erlc`)
- Bun

## Protocol

TCP frames use a 4-byte unsigned big-endian payload length prefix (`{packet, 4}` on the Erlang side).

Request payload (21 bytes): request ID (4-byte unsigned), opcode (1 byte; `1` means add), A (8-byte signed integer), B (8-byte signed integer). All multi-byte values are big-endian.

Response payload (13 bytes): request ID (4-byte unsigned), status (1 byte; `0` success, `1` error), result (8-byte signed integer).

This starter implementation handles requests sequentially per connection. It is a protocol example, not a performance benchmark or production-ready service.

## Quick start

```sh
bun install
```

**Terminal 1 — server.** Compiles the module and binds the port:

```sh
bun run server
```

**Terminal 2 — client:**

```sh
bun run start
```

Expected output:

```text
10 + 20 = 30
9000000000 + 1 = 9000000001
-2 + 7 = 5
```

Other scripts:

| Script | Purpose |
|---|---|
| `bun run server` | Compile `bridge_server.erl`, then start it on port 4040 |
| `bun run start` | Run the client (`src/client.ts`) |
| `bun run typecheck` | Type-check the client with `tsc --noEmit` |
| `bun run test` | Run the EUnit suite for the Erlang server |
| `bun run docs` | Generate the Erlang API reference into `doc/` |

## Running the server by hand

`bun run server` is only a wrapper. The underlying steps are:

```sh
mkdir -p erlang
erlc -o erlang erlang/bridge_server.erl
erl -noshell -pa erlang -eval '
  case bridge_server:start_link(4040) of
    {ok, _Pids} -> receive stop -> ok end;
    Error -> io:format("~p~n", [Error]), halt(1)
  end.'
```

Note that `start_link/1` returns a **list** of acceptor pids, not a single pid. `bridge_server:stop/1` accepts either the list or one pid.

## Concurrency model

The server runs a fixed set of **acceptor** processes and one **worker** per connection:

- Each acceptor owns its own listening socket, all bound to the same port with `SO_REUSEPORT`. The kernel distributes incoming connections across them, so accepting runs in parallel rather than serialising behind a single accept loop.
- An acceptor never handles requests. It accepts a socket, spawns a worker, transfers socket ownership to it, and loops.
- Each worker serves one connection strictly sequentially, matching the protocol's lockstep semantics. Sockets use passive mode (`{active, false}`), so a slow client only ever blocks its own worker.
- Every blocking call has an explicit timeout: 1000 ms for accept, 30 s for receive. An idle connection is closed after 30 s.
- A shared `atomics` counter caps concurrent workers (default 128). Past the cap, new connections are closed immediately rather than queued.

Defaults follow the machine: the acceptor count is the number of online schedulers, capped at 8. Override either with `start_link/3`:

```erlang
%% 4 acceptors, at most 32 concurrent workers
{ok, Pids} = bridge_server:start_link(4040, 4, 32).
```

### Multiple instances share the port

Because every listening socket sets `SO_REUSEPORT`, starting a **second** server on the same port does not fail with `eaddrinuse` — it binds successfully, and the kernel splits connections between the instances. This is what allows scaling across processes and hosts, but it also means a duplicate launch is silent rather than an error. If you want to detect that case yourself, check for a listener on the port before starting.

## Erlang API

| Function | Description |
|---|---|
| `start_link(Port)` | Start with default acceptor count and connection cap |
| `start_link(Port, AcceptorCount)` | Start with an explicit acceptor count |
| `start_link(Port, AcceptorCount, MaxConnections)` | Start with both explicit; pass `undefined` for either to take the default |
| `acceptor_count()` | The default acceptor count (schedulers, capped at 8) |
| `connection_limit()` | The default concurrent worker cap (128) |
| `stop(Pids)` | Stop the server; accepts a pid or list of pids |

`start_link/1,2,3` returns `{ok, Pids}` or `{error, Reason}`. If any acceptor fails to bind, the ones that already started are stopped, so no listener is left behind. It is linked to the calling process and is not an OTP behaviour process — there is no supervision tree, and `stop/1` returns before the listeners have actually closed (allow up to 1000 ms).

### Generated API reference

The module carries edoc comments. To render them as HTML:

```sh
bun run docs          # writes doc/ (gitignored)
```

Then open `doc/index.html` in a browser, or serve it:

```sh
python3 -m http.server 8765 --directory doc
```

## Tests

```sh
bun run test
```

The EUnit suite in `test/bridge_server_tests.erl` covers the protocol (arithmetic, 64-bit boundaries and overflow, malformed frames), the concurrency guarantees (the connection cap holds and slots are reclaimed), and the API surface. It also asserts the multi-instance behaviour described above, so removing `{reuseport, true}` fails the suite rather than silently changing semantics. Each test uses its own port, so they can run alongside a server on 4040.

## Run the client on another machine

Replace `192.0.2.10` with the server's reachable IP address:

```sh
ERLANG_HOST=192.0.2.10 ERLANG_PORT=4040 bun run src/client.ts
```

Expected output:

```text
10 + 20 = 30
9000000000 + 1 = 9000000001
-2 + 7 = 5
```

## Security and production notes

The server binds to all interfaces and has no authentication or TLS. Only run it on a trusted private network or behind a firewall/VPN. Note that `SO_REUSEPORT` means any local process running as the same user can bind the port as well.

There is a connection cap (default 128) and a 1 MiB frame cap, but no per-client rate limiting. Malformed frames close the connection silently — nothing is logged, so a client sending garbage leaves no trace.

For production, add TLS or private-network authentication, request deadlines, version negotiation, explicit error codes, monitoring, and supervised workers. `start_link/1` is not a supervisor behaviour; wrap it in one. Benchmark using the real workload before assuming TCP improves throughput.

## Known limitations

- A duplicate server launch on the same port is silent rather than an error (see above).
- Malformed traffic is not logged; a client sending garbage leaves no trace.
- The client handles one in-flight request at a time, by design. There is no multiplexing or request pipelining.
- Neither side negotiates a protocol version.
