/**
 * Client for the erl_bridge TCP bridge, protocol v2.
 *
 * Configuration comes from the environment:
 *
 *   ERL_BRIDGE_HOST    default 127.0.0.1
 *   ERL_BRIDGE_PORT    default 4040
 *   ERL_BRIDGE_TOKEN   shared secret; omit when the server has auth off
 *   ERL_BRIDGE_TLS     "1" to connect over TLS
 *   ERL_BRIDGE_TLS_CA  path to a CA certificate to verify the server
 *
 * The connection is one persistent TCP session. v2 adds a mandatory
 * HELLO handshake before any request: the client proposes the protocol
 * version and its token, and the server answers with the version it will
 * speak. A rejected handshake gets a distinct status, so a client that
 * cannot connect can say *why* rather than reporting a mysterious close.
 */

import { readFileSync } from "node:fs";
import { connect as connectTcp, type Socket } from "node:net";
import { connect as connectTls, type ConnectionOptions, type TLSSocket } from "node:tls";

const PROTOCOL_VERSION = 2;

const HELLO_OK = 0;
const HELLO_BAD_VERSION = 1;
const HELLO_AUTH_FAILED = 2;

const HOST = Bun.env.ERL_BRIDGE_HOST ?? "127.0.0.1";
const PORT = Number(Bun.env.ERL_BRIDGE_PORT ?? "4040");
const TOKEN = Bun.env.ERL_BRIDGE_TOKEN ?? "";
const USE_TLS = (Bun.env.ERL_BRIDGE_TLS ?? "0") === "1";
const CA = Bun.env.ERL_BRIDGE_TLS_CA;

if (!Number.isInteger(PORT) || PORT < 1 || PORT > 65535) {
  throw new Error(`Invalid ERL_BRIDGE_PORT: ${Bun.env.ERL_BRIDGE_PORT}`);
}

type AnySocket = Socket | TLSSocket;

/**
 * Frames the socket and tracks the single in-flight request.
 *
 * `#settle` is the only place a request's promise is resolved or
 * rejected, and it clears `#pending` -- which is what makes a double
 * settle impossible. The socket listeners stay attached for the life of
 * the connection: they are what *parse* the stream, so detaching them
 * after the first response would silently stop every response after it.
 */
class Connection {
  readonly #socket: AnySocket;
  #buffered = Buffer.alloc(0);
  #pending: { resolve: (payload: Buffer) => void; reject: (error: Error) => void } | undefined;

  constructor(socket: AnySocket) {
    this.#socket = socket;
    this.#socket.on("data", this.#onData);
    this.#socket.on("error", this.#onError);
    this.#socket.on("close", this.#onClose);
    // An idle timer, not a deadline. Node clears it when the socket
    // closes, which is precisely why `close` needs its own handler below.
    this.#socket.setTimeout(30_000, this.#onTimeout);
  }

  /**
   * Completes the in-flight request, if any.
   *
   * Clearing `#pending` is what makes this idempotent: `close` always
   * follows `error`, so a single failure arrives twice and the second
   * call finds nothing left to settle.
   */
  #settle = (error: Error | undefined, payload?: Buffer): void => {
    const pending = this.#pending;
    this.#pending = undefined;
    if (error) pending?.reject(error);
    else pending?.resolve(payload ?? Buffer.alloc(0));
  };

  #onData = (chunk: Buffer): void => {
    this.#buffered = Buffer.concat([this.#buffered, chunk]);
    while (this.#buffered.length >= 4) {
      const payloadLength = this.#buffered.readUInt32BE(0);
      if (payloadLength > 1_048_576) {
        this.#settle(new Error(`Frame too large: ${payloadLength}`));
        this.#socket.destroy();
        return;
      }
      if (this.#buffered.length < 4 + payloadLength) return;
      // `payload` is a view into the old `buffered`. That stays valid
      // because the next Buffer.concat allocates fresh memory rather than
      // reusing the old buffer -- don't replace the concat with a pooled
      // write here.
      const payload = this.#buffered.subarray(4, 4 + payloadLength);
      this.#buffered = this.#buffered.subarray(4 + payloadLength);
      this.#settle(undefined, payload);
    }
  };

  #onError = (error: Error): void => this.#settle(error);

  // A clean FIN emits no "error", and setTimeout() is cleared on close --
  // so without this handler an in-flight request would never settle and
  // the process would hang. "close" always follows "error"; the guard in
  // #settle makes the duplicate harmless.
  #onClose = (): void =>
    this.#settle(new Error("Connection closed by the server before a response arrived"));

  #onTimeout = (): void => {
    this.#settle(new Error("TCP socket timed out"));
    this.#socket.destroy();
  };

  /** Sends one frame and waits for the next one. */
  #exchange(payload: Buffer): Promise<Buffer> {
    if (this.#pending) {
      return Promise.reject(new Error("This demo allows one in-flight request at a time"));
    }
    // The 4-byte length prefix is added here, not at the call sites. Doing
    // it in each caller is how the handshake once shipped a bare payload:
    // the server read that payload's own first bytes as a length header and
    // the connection simply went quiet.
    const frame = Buffer.alloc(4 + payload.length);
    frame.writeUInt32BE(payload.length, 0);
    payload.copy(frame, 4);

    return new Promise<Buffer>((resolve, reject) => {
      this.#pending = { resolve, reject };
      this.#socket.write(frame, (error) => {
        if (error) this.#settle(error);
      });
    });
  }

  /**
   * Performs the HELLO handshake. Resolves only when the server accepts
   * this protocol version and this token.
   */
  async handshake(token: string): Promise<void> {
    const tokenBytes = Buffer.from(token, "utf8");
    if (tokenBytes.length > 512) {
      throw new Error(`Token too large: ${tokenBytes.length} bytes (max 512)`);
    }
    const hello = Buffer.alloc(3 + tokenBytes.length);
    hello.writeUInt8(PROTOCOL_VERSION, 0);
    hello.writeUInt16BE(tokenBytes.length, 1);
    tokenBytes.copy(hello, 3);

    const ack = await this.#exchange(hello);
    if (ack.length !== 2) {
      throw new Error(`Malformed HELLO_ACK: ${ack.length} bytes, expected 2`);
    }
    const version = ack.readUInt8(0);
    const status = ack.readUInt8(1);

    switch (status) {
      case HELLO_OK:
        if (version !== PROTOCOL_VERSION) {
          throw new Error(`Server negotiated unexpected version ${version}`);
        }
        return;
      case HELLO_BAD_VERSION:
        throw new Error(
          `Server rejected protocol version ${PROTOCOL_VERSION} ` +
            `(it speaks ${version === 0 ? "some other version" : version})`,
        );
      case HELLO_AUTH_FAILED:
        throw new Error("Server rejected the auth token");
      default:
        throw new Error(`Unknown HELLO_ACK status ${status}`);
    }
  }

  /** Sends one add request and returns { status, result }. */
  async add(id: number, a: bigint, b: bigint): Promise<{ status: number; result: bigint }> {
    const payload = Buffer.alloc(21);
    payload.writeUInt32BE(id, 0);
    payload.writeUInt8(1, 4); // opcode: add
    payload.writeBigInt64BE(a, 5);
    payload.writeBigInt64BE(b, 13);

    const response = await this.#exchange(payload);
    if (response.length !== 13) {
      throw new Error(`Unexpected response size: ${response.length}`);
    }
    const responseId = response.readUInt32BE(0);
    if (responseId !== id) {
      throw new Error(`Response ID mismatch: expected ${id}, got ${responseId}`);
    }
    return { status: response.readUInt8(4), result: response.readBigInt64BE(5) };
  }

  end(): void {
    this.#socket.end();
  }
}

function openSocket(): Promise<AnySocket> {
  if (USE_TLS) {
    // Bun's TLS stack wants the certificate *contents*, not a path, so
    // read it here. Passing the path yields "Invalid CA".
    const options: ConnectionOptions = CA
      ? { host: HOST, port: PORT, ca: readFileSync(CA, "utf8") }
      : { host: HOST, port: PORT };
    return new Promise((resolve, reject) => {
      const socket = connectTls(options);
      socket.once("secureConnect", () => resolve(socket));
      socket.once("error", reject);
    });
  }
  return new Promise((resolve, reject) => {
    const socket = connectTcp({ host: HOST, port: PORT });
    socket.once("connect", () => resolve(socket));
    socket.once("error", reject);
  });
}

async function main(): Promise<void> {
  const socket = await openSocket();
  const connection = new Connection(socket);
  try {
    await connection.handshake(TOKEN);

    const cases: Array<[bigint, bigint]> = [
      [10n, 20n],
      [9_000_000_000n, 1n],
      [-2n, 7n],
    ];

    let id = 1;
    for (const [a, b] of cases) {
      const { status, result } = await connection.add(id, a, b);
      if (status !== 0) throw new Error(`Erlang returned status ${status}`);
      if (result !== a + b) throw new Error(`Wrong result: expected ${a + b}, got ${result}`);
      console.log(`${a} + ${b} = ${result}`);
      id++;
    }

    // The 64-bit boundary: the extremes are representable, so these must
    // succeed; a sum that leaves the range reports status 1 instead of
    // wrapping into a corrupt field.
    const max = 9_223_372_036_854_775_807n;
    const boundary = await connection.add(id, max - 1n, 1n);
    if (boundary.status !== 0 || boundary.result !== max) {
      throw new Error(`Boundary failure: status ${boundary.status}, result ${boundary.result}`);
    }
    const overflow = await connection.add(id + 1, max, 1n);
    if (overflow.status !== 1) {
      throw new Error(`Expected overflow status 1, got ${overflow.status}`);
    }
    console.log(`max + 1 correctly reported as overflow`);
  } finally {
    connection.end();
  }
}

await main();
