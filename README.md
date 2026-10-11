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

## Start the server

From this directory:

```sh
mkdir -p erlang
erlc -o erlang erlang/bridge_server.erl
erl -noshell -pa erlang -eval '
  case bridge_server:start_link(4040) of
    {ok, _Pid} -> receive stop -> ok end;
    Error -> io:format("~p~n", [Error]), halt(1)
  end.'
```

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

The server binds to all interfaces and has no authentication or TLS. Only run it on a trusted private network or behind a firewall/VPN. For production, add TLS or private-network authentication, connection limits, request deadlines, bounded queues, version negotiation, explicit error codes, monitoring, and supervised concurrent workers. Benchmark using the real workload before assuming TCP improves throughput.
