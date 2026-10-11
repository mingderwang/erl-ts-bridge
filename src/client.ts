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

socket.on("data", (chunk: Buffer) => {
  buffered = Buffer.concat([buffered, chunk]);
  while (buffered.length >= 4) {
    const payloadLength = buffered.readUInt32BE(0);
    if (payloadLength > 1_048_576) {
      pendingReject?.(new Error(`Frame too large: ${payloadLength}`));
      socket.destroy();
      return;
    }
    if (buffered.length < 4 + payloadLength) return;
    const payload = buffered.subarray(4, 4 + payloadLength);
    buffered = buffered.subarray(4 + payloadLength);
    const resolve = pendingResolve;
    pendingResolve = undefined;
    pendingReject = undefined;
    resolve?.(payload);
  }
});

socket.on("error", (error) => pendingReject?.(error));
socket.setTimeout(30_000, () => {
  pendingReject?.(new Error("TCP socket timed out"));
  socket.destroy();
});

function connect(): Promise<void> {
  return new Promise((resolve, reject) => {
    socket.once("connect", resolve);
    socket.once("error", reject);
  });
}

function request(id: number, a: bigint, b: bigint): Promise<Buffer> {
  if (pendingResolve) throw new Error("This demo allows one in-flight request at a time");
  const payload = Buffer.alloc(21);
  payload.writeUInt32BE(id, 0);
  payload.writeUInt8(1, 4); // opcode: add
  payload.writeBigInt64BE(a, 5);
  payload.writeBigInt64BE(b, 13);
  const frame = Buffer.alloc(4 + payload.length);
  frame.writeUInt32BE(payload.length, 0);
  payload.copy(frame, 4);

  return new Promise((resolve, reject) => {
    pendingResolve = resolve;
    pendingReject = reject;
    socket.write(frame, (error) => {
      if (error) {
        pendingResolve = undefined;
        pendingReject = undefined;
        reject(error);
      }
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
    console.log(`${a} + ${b} = ${result}`);
    id++;
  }
} finally {
  socket.end();
}
