import { createConnection, type Socket } from "node:net";

const host = Bun.env.ERLANG_HOST ?? "127.0.0.1";
const port = Number(Bun.env.ERLANG_PORT ?? "4040");
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error(`Invalid ERLANG_PORT: ${port}`);
}

const socket: Socket = createConnection({ host, port });
let buffered = Buffer.alloc(0);
let pendingResolve: ((payload: Buffer) => void) | undefined;
let pendingReject: ((error: Error) => void) | undefined;

// Settles the in-flight request, if any. Clears both handlers so a
// late or duplicate event cannot settle the same promise twice.
function settle(error: Error | undefined, payload?: Buffer): void {
  const resolve = pendingResolve;
  const reject = pendingReject;
  pendingResolve = undefined;
  pendingReject = undefined;
  if (error) reject?.(error);
  else resolve?.(payload as Buffer);
}

socket.on("data", (chunk: Buffer) => {
  buffered = Buffer.concat([buffered, chunk]);
  while (buffered.length >= 4) {
    const payloadLength = buffered.readUInt32BE(0);
    if (payloadLength > 1_048_576) {
      settle(new Error(`Frame too large: ${payloadLength}`));
      socket.destroy();
      return;
    }
    if (buffered.length < 4 + payloadLength) return;
    // `payload` is a view into the old `buffered`. That stays valid because
    // the next Buffer.concat allocates a fresh buffer rather than reusing
    // the old one -- don't replace the concat with a pooled write here.
    const payload = buffered.subarray(4, 4 + payloadLength);
    buffered = buffered.subarray(4 + payloadLength);
    // A frame with no request in flight cannot be delivered to anyone.
    // There is no pending promise to reject, so drop it rather than
    // throwing from inside an event handler.
    settle(undefined, payload);
  }
});

socket.on("error", (error) => settle(error));

// A clean FIN does not emit "error", and socket.setTimeout() is an idle
// timer that Node clears once the socket closes -- so without this
// handler an in-flight request would never settle and the process would
// hang. Node guarantees "close" fires after "error", so settling here
// too is harmless: the first settle wins and clears the handlers.
socket.on("close", () => {
  settle(new Error("Connection closed by the server before a response arrived"));
});

socket.setTimeout(30_000, () => {
  settle(new Error("TCP socket timed out"));
  socket.destroy();
});

function connect(): Promise<void> {
  return new Promise((resolve, reject) => {
    // Remove both listeners on either outcome, so a later error cannot
    // reach the already-settled connect promise.
    const onConnect = () => {
      socket.off("error", onError);
      resolve();
    };
    const onError = (error: Error) => {
      socket.off("connect", onConnect);
      reject(error);
    };
    socket.once("connect", onConnect);
    socket.once("error", onError);
  });
}

function request(id: number, a: bigint, b: bigint): Promise<Buffer> {
  return new Promise<Buffer>((resolve, reject) => {
    if (pendingResolve) {
      reject(new Error("This demo allows one in-flight request at a time"));
      return;
    }
    const payload = Buffer.alloc(21);
    payload.writeUInt32BE(id, 0);
    payload.writeUInt8(1, 4); // opcode: add
    payload.writeBigInt64BE(a, 5);
    payload.writeBigInt64BE(b, 13);
    const frame = Buffer.alloc(4 + payload.length);
    frame.writeUInt32BE(payload.length, 0);
    payload.copy(frame, 4);

    pendingResolve = resolve;
    pendingReject = reject;
    socket.write(frame, (error) => {
      if (error) settle(error);
    });
  });
}

try {
  await connect();
  const cases: Array<[bigint, bigint]> = [
    [10n, 20n],
    [9_000_000_000n, 1n],
    [-2n, 7n],
  ];
  let id = 1;
  for (const [a, b] of cases) {
    const response = await request(id, a, b);
    if (response.length !== 13) throw new Error(`Unexpected response size: ${response.length}`);
    const responseId = response.readUInt32BE(0);
    const status = response.readUInt8(4);
    const result = response.readBigInt64BE(5);
    if (responseId !== id) throw new Error(`Response ID mismatch: expected ${id}, got ${responseId}`);
    if (status !== 0) throw new Error(`Erlang returned status ${status}`);
    if (result !== a + b) throw new Error(`Wrong result: expected ${a + b}, got ${result}`);
    console.log(`${a} + ${b} = ${result}`);
    id++;
  }
} finally {
  socket.end();
}