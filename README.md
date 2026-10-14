# Erlang ↔ Bun/TypeScript TCP bridge

A persistent TCP connection between an Erlang/OTP server and a Bun +
TypeScript client, with authentication, optional TLS, metrics, and a
supervision tree.

It deliberately does one thing — send a signed 64-bit addition over a
framed socket and read the reply — so the interesting content is the
plumbing rather than the arithmetic.

## Requirements

- Erlang/OTP 29+ (`erl`, `erlc`, `rebar3`)
- Bun

## Quick start

```sh
bun install
rebar3 compile
```

**Terminal 1 — server.** Compiles and binds port 4040:

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
max + 1 correctly reported as overflow
```

### Scripts

| Script | Purpose |
|---|---|
| `bun run server` | Start the server on port 4040 (foreground) |
| `bun run console` | Interactive Erlang shell with the app loaded |
| `bun run start` | Run the client |
| `bun run test` | Run the EUnit suite |
| `bun run typecheck` | Type-check the client |
| `bun run lint` | Run xref and dialyzer |
| `bun run docs` | Generate the edoc HTML reference into `doc/` |
| `bun run check` | Compile, xref, eunit, dialyzer, typecheck |

## Protocol

Version 2, with a mandatory HELLO handshake before any request: the client
proposes a protocol version and its auth token, and the server replies with
the version it will speak. See [PROTOCOL.md](PROTOCOL.md) for the byte
layout.

Version 1 was unauthenticated and is **no longer accepted**. A client
speaking v1 gets a `HELLO_BAD_VERSION` acknowledgement and is disconnected.

## Configuration

Resolved once at startup, in increasing order of precedence: built-in
defaults, the application environment (`sys.config`), `ERL_BRIDGE_*`
environment variables, then arguments passed to `bridge_server:start/1`.

| Setting | Env var | Default | Meaning |
|---|---|---|---|
| `port` | `ERL_BRIDGE_PORT` | 4040 | Listen port; 0 asks the OS |
| `acceptor_count` | `ERL_BRIDGE_ACCEPTORS` | schedulers, max 8 | Acceptor processes |
| `max_connections` | `ERL_BRIDGE_MAX_CONNECTIONS` | 128 | Global concurrent worker cap |
| `max_frame_size` | `ERL_BRIDGE_MAX_FRAME_SIZE` | 1 MiB | Largest accepted frame |
| `handshake_timeout` | `ERL_BRIDGE_HANDSHAKE_TIMEOUT` | 5000 ms | HELLO deadline |
| `request_timeout` | `ERL_BRIDGE_REQUEST_TIMEOUT` | 30000 ms | Per-request idle deadline |
| `shutdown_grace` | `ERL_BRIDGE_SHUTDOWN_GRACE` | 5000 ms | Graceful stop budget |
| `token` | `ERL_BRIDGE_TOKEN` | *none* | Shared secret; auth is off when unset |
| `reuseport` | `ERL_BRIDGE_REUSEPORT` | `true` | `SO_REUSEPORT` on the listener |
| `tls` | `ERL_BRIDGE_TLS_CERTFILE` + `ERL_BRIDGE_TLS_KEYFILE` | *none* | Enables TLS |
| `metrics_port` | `ERL_BRIDGE_METRICS_PORT` | *none* | Enables the `/metrics` endpoint |

Everything is validated at boot: a bad value fails with one clear message
rather than surfacing as a confusing error in an acceptor ten seconds
later. No long-lived process reads the environment, so exporting a
variable cannot silently reconfigure a running server.

### Authentication

Set a token and every client must present it in the HELLO handshake:

```sh
export ERL_BRIDGE_TOKEN="$(openssl rand -hex 32)"
```

Comparison uses `crypto:hash_equals/2`, so a wrong token takes the same
time regardless of how many leading bytes were right.

**With no token configured, authentication is off** and any peer that
connects can send requests. The server logs a warning at boot saying so —
"no auth" is a visible choice, never a silent default.

### TLS

Optional, off by default. Supply a certificate and key:

```sh
export ERL_BRIDGE_TLS_CERTFILE=cert.pem
export ERL_BRIDGE_TLS_KEYFILE=key.pem
bun run server
```

The client connects over TLS with `ERL_BRIDGE_TLS=1`, optionally verifying
against a CA with `ERL_BRIDGE_TLS_CA`. TLS and authentication compose;
either can be enabled without the other.

## Architecture

```
erl_bridge_app            application callback; resolves config, then starts
└── erl_bridge_sup        top supervisor
    ├── erl_bridge_metrics        counters/gauges in ETS
    ├── erl_bridge_metrics_http   /metrics (only when configured)
    └── erl_bridge_acceptor_sup    acceptor pool
        └── erl_bridge_acceptor  × N, one shared listening socket
            └── erl_bridge_conn  × M, one per connection
```

- Each acceptor holds the **same** listening socket (`SO_REUSEPORT`), so
  the kernel spreads incoming connections across them. The socket is
  owned by `erl_bridge_acceptor_sup` and closed once, after every acceptor
  has exited — an acceptor closing it would break the others.
- Acceptors are plain processes with an explicit `receive`. An earlier
  `gen_server` version drove the loop from a timeout message and could
  silently stop accepting; see the module docs for why.
- Each connection is a `gen_server` that performs at most one bounded
  receive per callback and yields in between, so it stays responsive to
  shutdown rather than sitting inside one long `recv`.
- The connection cap is enforced against a **shared** `atomics` counter.
  A per-acceptor counter would silently multiply the limit by the
  acceptor count.

### Erlang API

| Function | Description |
|---|---|
| `bridge_server:start/0,1,2` | Start the supervised application |
| `bridge_server:stop/0` | Stop it, with a grace period |
| `bridge_server:running/0` | Whether it is up |
| `bridge_server:info/0` | Config, child pids, connection count, metrics |
| `bridge_server:generate_token/1` | Generate a hex-encoded random token |

`start_link/0,1,2` were renamed to `start/0,1,2` in 2.0 — they never were
link-only constructors, and they now start a supervised application. The
old names still work but are deprecated and will be removed in 3.0.

`stop/0` returns once the tree is down; an acceptor needs up to one accept
timeout (default 1 s) to notice.

## Metrics

Set `ERL_BRIDGE_METRICS_PORT` to expose Prometheus metrics on
`127.0.0.1:<port>/metrics`:

```
erl_bridge_requests_ok_total 1042
erl_bridge_requests_overflow_total 0
erl_bridge_handshake_auth_failed_total 3
erl_bridge_connections_active 2
```

Counters carry a `_total` suffix; gauges do not. Every series is
pre-seeded at zero, because Prometheus reads a missing series as *no data*
rather than zero, which would silently break `rate()`.

The endpoint **binds to loopback only** and is unauthenticated. If a
remote host must scrape it, put a proxy that authenticates in front.

### Telemetry

The server also emits ordinary [`telemetry`](https://hexdocs.pm/telemetry)
events under `erl_bridge.*` — `connection.open`, `handshake.success`,
`handshake.failure`, `request.idle_timeout`. Any backend can be attached
in `erl_bridge_app:start/2` without touching call sites.

The only dependency is `telemetry` itself. `telemetry_metrics_prometheus_core`
was deliberately avoided: every release of `telemetry_metrics` is a mix
project with no `rebar.config`, so it would force Elixir into an
Erlang-only toolchain.

## Tests

```sh
bun run test
```

70 EUnit tests: pure protocol encoding, config resolution and validation,
token comparison, metrics rendering, and integration tests that start the
real application and drive it over real sockets — handshake, version
rejection, auth accept/reject, the connection cap, metrics, supervision,
restart, and TLS.

Integration tests bind port 0, so they cannot collide with a server on
4040. The TLS tests generate a throwaway self-signed certificate with
`openssl` and skip if it is unavailable.

## Run the client against another machine

```sh
ERL_BRIDGE_HOST=192.0.2.10 ERL_BRIDGE_PORT=4040 bun run src/client.ts
```

Client variables: `ERL_BRIDGE_HOST`, `ERL_BRIDGE_PORT`,
`ERL_BRIDGE_TOKEN`, `ERL_BRIDGE_TLS`, `ERL_BRIDGE_TLS_CA`.

## Security and production notes

The server has no TLS or authentication unless you configure them, and no
per-client rate limiting — the connection cap bounds concurrency, not
request rate. Put it on a trusted network or behind a proxy.

`SO_REUSEPORT` means any local process running as the same user can bind
the port as well, so a duplicate launch is silent. Set
`ERL_BRIDGE_REUSEPORT=false` if you would rather a duplicate launch fail
loudly with `eaddrinuse`; with it off, a single instance owns the port.

Still to add for a real service: per-client rate limiting, authorisation
of individual operations, request pipelining, and a protocol version
registry for negotiating future changes.

## Generated API reference

```sh
bun run docs
python3 -m http.server 8765 --directory doc
```
