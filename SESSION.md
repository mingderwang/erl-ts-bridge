# Session Summary

**Date:** 2026-10-11
**Project:** `erl-ts-bridge 2` — Erlang/OTP ↔ Bun/TypeScript TCP bridge demo
**Environment:** macOS (arm64), Erlang/OTP 29.1 (mise), Bun 1.3.14, git 2.54.0

---

## Update log (added after publication)

This document was originally written as scratch notes and later committed. The
snapshot below describes state at the time of writing; these changes came after:

- **Published** to https://github.com/mingderwang/erl-ts-bridge (public, `main`)
- **Commit history rewritten** to attribute both commits to `mingderwang`
  (`47238+mingderwang@users.noreply.github.com`) instead of `mingneedbeer`.
  Tree hash was verified identical before and after; content unchanged.
- **`SESSION.md` is now committed** — the `.gitignore` rule that excluded it was
  removed. Section 4's "9 files" count is therefore stale.
- **`.env.example` added** as a documented template. `.env` remains tracked; it
  contains no credentials, only loopback host/port defaults.
- **Findings #1, #2, #4, #5 and #6 are fixed** in `src/client.ts`. The client's
  settle paths now go through a single `settle/2`, and the demo asserts its result.
  Sections 1–2 mark each accordingly; the remaining open items are #3's follow-ups
  and the low-priority notes.

## Current status

All blocking and high-severity findings from the original review are resolved. The
Erlang server has multi-acceptor concurrency with a bounded connection cap, and
`bun run test` covers the protocol, the concurrency guarantees, and the API
surface. The open items in section 6 are documentation and convention suggestions,
not defects.

---

## 1. Initial request: code review

Reviewed all four original files (`README.md`, `PROTOCOL.md`,
`erlang/bridge_server.erl`, `src/client.ts`).

### What was verified as correct

The happy path runs end-to-end and produces exactly the documented output.
Every documented error path was probed against the real server and matched:

| Probe | Result |
|---|---|
| `max_int64 + 1` | `status=1`, result 0, connection closed ✓ |
| `min_int64 - 1` | `status=1`, result 0, connection closed ✓ |
| `max_int64 - 1 + 1` | `status=0`, `9223372036854775807` ✓ |
| bad opcode `7` | connection closed ✓ |
| short payload (10 B) | connection closed ✓ |

Specific good calls worth preserving:

- **`fits_int64/1` overflow guard** is genuinely necessary — Erlang bignums would
  otherwise silently wrap and emit a corrupt 64-bit field.
- **Tail recursion** through `send_reply` → `serve_loop` is correct.
- **`{packet, 4}` / `{active, false}` inheritance** from the listen socket to
  accepted sockets is correct, so framing works without re-setting options.
- **`PROTOCOL.md` matches the implementation exactly** — offsets, endianness,
  and close-on-malformed behaviour all check out.

---

## 2. Findings

### Blocking

**1. `src/client.ts` hangs forever if the peer closes mid-request.** — **FIXED**

There is no `'close'` / `'end'` handler, and `socket.on("error", …)` fires only
for socket errors — not a clean FIN. The `setTimeout(30_000, …)` safety net does
not help: it is an *idle* timer that Node clears when the socket closes. So
`await request(...)` never settles; the process wedges silently.

*Empirical confirmation:* the client's exact request logic was replayed against a
server that accepts then disconnects. It ran past 60 s without settling, and still
hung when the timer was cut to 1.5 s — proving the timer is cleared rather than
firing.

Reachable via the server's own malformed/overflow paths, so the two halves of the
demo disagree about failure behaviour.

*Fix applied:* added a `'close'` handler and consolidated every settle path
(`data`, `error`, `close`, `timeout`, write-callback) through a single
`settle/2` that clears both handlers, so a late event cannot settle the same
promise twice. `request/3` now rejects instead of throwing synchronously (item 4),
`connect/0` removes both of its listeners on either outcome (item 6), and the demo
now asserts `result === a + b` (item 2).

*Verified:* against a server that accepts then disconnects, the request rejects in
~3 ms instead of hanging indefinitely; against the real client against a closing
server, ~91 ms. A correct response followed by a close does not trip the handler,
and the pending handlers are still undefined afterwards.

### High

**2. The demo never asserts the answer.** `client.ts:86` logs
`` `${a} + ${b} = ${result}` `` but never checks `result === a + b`. The client
would print `10 + 20 = 999` and exit 0. The overflow path (`status=1`) is never
exercised either, leaving the client's error branch untested.
**— FIXED:** the client now throws `Wrong result: expected 30, got 999` when the
server returns a wrong value. Verified against a stub server that answers `999` on
purpose: the client fails and exits non-zero.

**3. No `tsconfig.json` / `package.json`** — `bun run` only transpiles, so the
client had never been typechecked. Confirmed it failed outright
(`Cannot find type definition file for 'bun'`). **Fixed this session.**

### Medium

4. **`request()` throws synchronously but is typed `Promise<Buffer>`**
   (`client.ts:47`). Callers using `.catch()` miss it; `await` works only by
   accident, because the call happens to sit inside a `try`.
   **— FIXED:** the one-in-flight guard now rejects instead of throwing.
5. **Errors silently vanish** — `socket.on("error", e => pendingReject?.(e))`
   discards any error arriving with no request in flight.
   **— PARTIALLY FIXED:** errors now route through `settle/2`, which keeps the
   existing behaviour of ignoring an error with nothing in flight (there is no
   promise to reject), but prevents a stale handler from firing later.
6. **`connect()` leaks a listener** — the `once("error", reject)` at
   `client.ts:42` is never removed on success and swallows the connection's
   first error. **— FIXED:** `connect/0` removes both listeners on either outcome.
7. **Unbounded connection concurrency** — `accept_loop` spawns a worker per
   connection with no cap. Trivial DoS. README acknowledges it, so it is a
   scoping decision rather than a defect.

### Low / notes

8. **No observability** — `serve_loop` returns `{error, malformed_packet}` into a
   `try` whose value is discarded. Malformed traffic produces zero logs.
9. **`bridge_server.beam` was a committed build artifact.** **Fixed** via `.gitignore`.
10. **`start_link/1` is misnamed** — it is `spawn_link` + a `receive`, not an OTP
    behaviour. Not supervised, no crash reports. Worth renaming to `start/1`.
11. **`{nodelay, true}` recommended as hygiene.** Honest caveat: with strict
    lockstep there is rarely unacked data outstanding, so Nagle usually will not
    bite here. Add it; do not expect a measurable win.
12. **`payload` at `client.ts:24` is a `subarray` view, not a copy** — safe *only*
    because the next `Buffer.concat` allocates fresh memory. Worth a comment so
    nobody "optimises" the concat away and introduces a use-after-free.

---

## 3. Changes made

Four files created; no changes to `client.ts` or the Erlang server.

| File | Purpose |
|---|---|
| `package.json` | ESM project, `start` + `typecheck` scripts, dev-only deps |
| `tsconfig.json` | Strict config; `types: ["bun"]` resolves `Bun.env` |
| `.gitignore` | `node_modules/`, `bun.lockb`, `erlang/*.beam`, `erl_crash.dump`, `.DS_Store` |
| `.env` | `ERLANG_HOST=127.0.0.1`, `ERLANG_PORT=4040` |

`bun install` pulled `@types/bun@1.4.2` and `typescript@5.9.3` and wrote `bun.lock`.

**Deliberate choices**

- `bun.lock` is tracked, `bun.lockb` ignored — per Bun's guidance (modern text
  lockfile belongs in version control).
- `.env` holds no credentials, so committing it keeps `bun run start` working from
  a fresh clone. This does depart from the common `.env.example` convention; the
  tradeoff is that `.env` is where secrets go later.

### Verification

- `bun run typecheck` → **exit 0**. `client.ts` passes `strict` +
  `noUncheckedIndexedAccess` with no suppressions.
- `bun run start` and `bun run src/client.ts` both succeed end-to-end.
- `.env` vs. shell-env precedence confirmed empirically: **real environment
  variables win**, so the README's `ERLANG_HOST=… bun run …` workflow is unaffected.
- `.gitignore` confirmed active — `erlang/bridge_server.beam` and `node_modules/`
  correctly excluded.

> Note: a clean typecheck does **not** imply the client is correct. Finding #1 is
> a runtime issue, and TypeScript permits `throw` inside a function declared
> `Promise<Buffer>`. The value of the tsconfig is that future edits get checked.

---

## 4. Git setup

Repository initialised on `main`. Single commit `e6b892b`, 9 files, 339 insertions.

```
.env  .gitignore  PROTOCOL.md  README.md  bun.lock
erlang/bridge_server.erl  package.json  src/client.ts  tsconfig.json
```

The pre-existing `.beam` needed no `git rm --cached` — it was never tracked, so
the ignore rule applied from the first `git add`.

**No remote is configured.** The repo is local-only; pushing needs a URL.

---

## 5. Runtime note: the flapping server

An intermittent `ECONNREFUSED 127.0.0.1:4040` appeared mid-session (run succeeded,
next run failed, next succeeded). Cause: the server had been launched as a
detached `nohup … &` background job inside a tool call, which the harness reaps.
Confirmed after the fact — port 4040 down, no `bridge_server` process.

**Not a project defect.** Run the server as a *foreground* process in its own
terminal; the blocking `receive stop` is intentional so it persists until closed.

```sh
# Terminal 1 — server
cd "/Users/mingderwang/Downloads/erl-ts-bridge 2"
mkdir -p erlang
erlc -o erlang erlang/bridge_server.erl
erl -noshell -pa erlang -eval '
  case bridge_server:start_link(4040) of
    {ok, _Pid} -> receive stop -> ok end;
    Error -> io:format("~p~n", [Error]), halt(1)
  end.'

# Terminal 2 — client
bun run src/client.ts
```

---

## 6. Outstanding work

Items 1–3 are **done**; the rest are documentation and convention suggestions
rather than defects.

1. ~~Add the `'close'` handler in `client.ts`~~ — **done** (#1)
2. ~~Assert `result === a + b`~~ — **done** (#2)
3. ~~Make `request()` reject instead of throwing; clean up the `connect()` listener~~ — **done** (#4, #6)
4. Log the discarded `malformed_packet` error (#8)
5. Optionally: `{nodelay, true}`, rename `start_link` → `start` (#11, #10).
   The connection cap (#7) and the `subarray` comment (#12) are already done.
6. Consider switching to `.env.example` + gitignored `.env` (`.env.example` exists;
   `.env` is still tracked)
7. Optional: repository topics for discoverability

Not applicable any more: `bun install && bun run typecheck` is documented in the
README, and a git remote is configured.