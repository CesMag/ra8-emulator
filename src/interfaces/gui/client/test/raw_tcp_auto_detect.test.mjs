import net from "node:net";
import { spawn } from "node:child_process";
import { resolve } from "node:path";
import {
  encodeFrame,
  encodeHello,
  decodeHello,
  splitFrames,
  Kind,
  PROTOCOL_MAGIC,
  PROTOCOL_VERSION
} from "../dist/index.js";

async function testRawTcpNonInterference() {
  console.log("=== EMPIRICAL TEST: Raw TCP RPC Non-Interference Auto-Detection ===");

  const port = 24893;
  const emulatorPath = resolve(import.meta.dirname, "../../../../../zig-out/bin/ra8_emulator");
  const fixtureElf = resolve(import.meta.dirname, "../../../../../tests/fixtures/gpio/blink.elf");

  const proc = spawn(emulatorPath, [
    "serve",
    "--listen",
    `tcp:127.0.0.1:${port}`,
    fixtureElf,
  ], {
    stdio: ["pipe", "pipe", "pipe"],
  });

  let serverStarted = false;
  proc.stderr.on("data", (data) => {
    const text = data.toString();
    if (text.includes("serve: listening on tcp:")) {
      serverStarted = true;
    }
  });

  const start = Date.now();
  while (!serverStarted && Date.now() - start < 5000) {
    await new Promise((r) => setTimeout(r, 100));
  }

  if (!serverStarted) {
    proc.kill();
    throw new Error("Server failed to start");
  }

  try {
    // Connect using RAW TCP socket (NOT WebSocket)
    const socket = new net.Socket();
    await new Promise((resolve, reject) => {
      socket.connect(port, "127.0.0.1", resolve);
      socket.on("error", reject);
    });

    console.log("Connected raw TCP socket. Sending raw Kind.Hello frame...");
    const helloPayload = encodeHello(0x0000ffff);
    const helloFrame = encodeFrame(Kind.Hello, helloPayload);

    // Send raw bytes directly (no HTTP GET, no WebSocket masking)
    socket.write(helloFrame);

    const receivedChunks = [];
    const responsePromise = new Promise((resolve, reject) => {
      socket.on("data", (chunk) => {
        receivedChunks.push(chunk);
        const combined = Buffer.concat(receivedChunks);
        const { frames } = splitFrames(new Uint8Array(combined));
        if (frames.length > 0) {
          resolve(frames[0]);
        }
      });
      socket.on("error", reject);
      setTimeout(() => reject(new Error("Timeout waiting for raw TCP response")), 3000);
    });

    const respFrame = await responsePromise;
    console.log(`Received raw frame: kind=${respFrame.kind}`);
    if (respFrame.kind !== Kind.Hello) {
      throw new Error(`Expected Kind.Hello (1), got ${respFrame.kind}`);
    }

    const decoded = decodeHello(respFrame.payload);
    console.log(`✓ Decoded raw server Hello: magic=0x${decoded.magic.toString(16)}, version=${decoded.version}, caps=0x${decoded.caps.toString(16)}`);

    if (decoded.magic !== PROTOCOL_MAGIC || decoded.version !== PROTOCOL_VERSION) {
      throw new Error("Invalid magic or version in raw response");
    }

    socket.end();
    console.log("✓ Raw TCP non-interference verified successfully!");

  } finally {
    proc.kill("SIGTERM");
  }
}

testRawTcpNonInterference().then(
  () => {
    console.log("\n>>> RAW TCP NON-INTERFERENCE TEST PASSED! <<<\n");
    process.exit(0);
  },
  (err) => {
    console.error("\n>>> RAW TCP NON-INTERFERENCE TEST FAILED:", err);
    process.exit(1);
  }
);
