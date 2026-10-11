# Wire protocol v1

All multi-byte integers are big-endian. TCP frames have a 4-byte unsigned big-endian length prefix. Erlang `{packet, 4}` adds/removes this prefix, so application code handles only payloads.

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

Unknown or malformed requests close the connection. This minimal protocol is illustrative; production services should define version negotiation, deadlines, request limits, authentication, and explicit error codes.
