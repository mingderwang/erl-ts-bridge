# Wire protocol v2

All multi-byte integers are big-endian. TCP frames carry a 4-byte unsigned
length prefix. Erlang's `{packet, 4}` adds and removes this prefix, so
application code handles only payloads.

## Handshake (required)

Every connection begins with a HELLO exchange. No request is served
before it completes.

The handshake exists for two reasons: to negotiate the protocol version,
and to authenticate. **Version 1 was unauthenticated and is no longer
accepted at all**, so this is a breaking change.

### HELLO — client to server, 3 + N bytes

| Offset | Size | Field |
|---:|---:|---|
| 0 | 1 | Protocol version the client speaks |
| 1 | 2 | Token length, unsigned 16-bit |
| 3 | N | Auth token, UTF-8 |

The announced token length is cross-checked against the actual payload
size; a mismatch is a malformed frame. Tokens longer than 512 bytes are
refused outright rather than buffered.

### HELLO_ACK — server to client, 2 bytes

| Offset | Size | Field |
|---:|---:|---|
| 0 | 1 | Negotiated version, or 0 if rejected |
| 1 | 1 | Status |

| Status | Meaning |
|---:|---|
| 0 | Accepted |
| 1 | Unsupported protocol version |
| 2 | Auth failed |

On success the version is echoed. On rejection it is zero, so a refused
client learns nothing beyond what it already guessed.

A rejected connection is closed immediately after the HELLO_ACK. The
distinct status codes matter: a client that cannot authenticate and a
client speaking the wrong protocol need different remedies.

## Request payload: 21 bytes

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | Request ID, unsigned 32-bit |
| 4 | 1 | Opcode (`1` = signed 64-bit addition) |
| 5 | 8 | A, signed 64-bit |
| 13 | 8 | B, signed 64-bit |

## Response payload: 13 bytes

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | Request ID, unsigned 32-bit |
| 4 | 1 | Status (`0` = success, `1` = error) |
| 5 | 8 | Result, signed 64-bit; zero on error |

## Connection-level behaviour

This section describes the reference server, not the wire format.

- Frames are capped at 1 MiB. A larger declared length is a malformed frame.
- Requests on a single connection are processed strictly sequentially: one
  request is read, answered, and only then is the next read.
- A connection that does not complete its handshake within
  `handshake_timeout` (default 5 s) is closed.
- A connection is closed after `request_timeout` (default 30 s) with no
  activity. The deadline resets after each response, so a connection that
  keeps sending stays open indefinitely.
- When the concurrent-connection cap is reached, incoming connections are
  closed immediately rather than queued.
- A 64-bit sum that would overflow returns `status=1` with a zero result
  rather than wrapping. This matters because Erlang has bignums: without
  the check, encoding the result would silently truncate into the 64-bit
  field and produce a confidently wrong answer.
- Unknown or malformed requests close the connection without a reply.
  Both are logged at warning level with the reason and peer.

This minimal protocol is illustrative; production services should still
define request limits, deadlines, explicit error codes, and authorisation
of individual operations.
