import assert from "node:assert/strict";
import {
  RA8RpcClient,
  Core,
  Register,
  Method,
  Kind,
  Topic,
  ErrorCode,
  TypedEventEmitter,
  splitFrames,
  encodeFrame,
  encodeHello,
  encodeResponse,
  encodeRequest,
  encodeDirtyRect,
  dirtyRectToRgba,
  detectPixelFormat,
} from "../dist/index.js";

async function runAdversarialSuite() {
  console.log("=== EMPIRICAL ADVERSARIAL CHALLENGE SUITE ===");

  let passed = 0;
  let failed = 0;

  async function test(name, fn) {
    try {
      await fn();
      console.log(`  ✓ ${name}`);
      passed++;
    } catch (err) {
      console.error(`  ✗ ${name}`);
      console.error(err);
      failed++;
    }
  }

  // --------------------------------------------------------------------------
  // Challenge 1: Concurrent / Pipelined Requests & ID Matching
  // --------------------------------------------------------------------------
  console.log("\n--- Challenge 1: Concurrent In-Flight Requests & ID Matching ---");

  await test("50 concurrent requests resolve to matching request IDs", async () => {
    class MockTransportWs {
      constructor() {
        this.readyState = 0; // CONNECTING
        this.onopen = null;
        this.onmessage = null;
        this.onclose = null;
        this.onerror = null;
        setTimeout(() => {
          this.readyState = 1;
          this.onopen?.({});
        }, 5);
      }
      send(data) {
        const { frames } = splitFrames(new Uint8Array(data));
        for (const frame of frames) {
          if (frame.kind === Kind.Hello) {
            const h = encodeFrame(Kind.Hello, encodeHello(0x1234));
            setTimeout(() => this.onmessage?.({ data: h.buffer }), 5);
          } else if (frame.kind === Kind.Request) {
            const view = new DataView(frame.payload.buffer, frame.payload.byteOffset, frame.payload.byteLength);
            const reqId = view.getUint32(0, true);
            // Simulate random jitter/delay in response order
            const jitter = 5 + Math.floor(Math.random() * 20);
            setTimeout(() => {
              // Return ack payload with the exact matching reqId
              const resp = encodeResponse(reqId, true, new Uint8Array([1]));
              const packet = encodeFrame(Kind.Response, resp);
              this.onmessage?.({ data: packet.buffer });
            }, jitter);
          }
        }
      }
      close() {
        this.readyState = 3;
        this.onclose?.({ code: 1000, reason: "Normal" });
      }
    }

    const client = new RA8RpcClient({ WebSocketClass: MockTransportWs, timeoutMs: 3000 });
    await client.connect("ws://mock.test:24880");

    const promises = [];
    for (let i = 0; i < 50; i++) {
      promises.push(client.step(Core.Cpu0));
    }

    const results = await Promise.all(promises);
    assert.equal(results.length, 50);
    for (const res of results) {
      assert.equal(res, true);
    }
    client.disconnect();
  });

  // --------------------------------------------------------------------------
  // Challenge 2: In-Flight Request Cleanup on Abrupt Disconnect
  // --------------------------------------------------------------------------
  console.log("\n--- Challenge 2: In-Flight Cleanup on Abrupt Disconnect ---");

  await test("pending calls reject immediately when connection drops abruptly", async () => {
    let wsInstance = null;
    class MockDropWs {
      constructor() {
        this.readyState = 0;
        this.onopen = null;
        this.onmessage = null;
        this.onclose = null;
        this.onerror = null;
        wsInstance = this;
        setTimeout(() => {
          this.readyState = 1;
          this.onopen?.({});
        }, 5);
      }
      send(data) {
        const { frames } = splitFrames(new Uint8Array(data));
        for (const frame of frames) {
          if (frame.kind === Kind.Hello) {
            const h = encodeFrame(Kind.Hello, encodeHello(0x1234));
            setTimeout(() => this.onmessage?.({ data: h.buffer }), 5);
          }
          // Intentionally do NOT respond to any request to simulate server hanging
        }
      }
      close() {
        this.readyState = 3;
        this.onclose?.({ code: 1006, reason: "Abnormal Closure" });
      }
    }

    const client = new RA8RpcClient({ WebSocketClass: MockDropWs, timeoutMs: 5000 });
    await client.connect("ws://mock.test:24880");

    const pendingCall = client.step(Core.Cpu0);

    // Abruptly simulate network drop from server side
    wsInstance.onclose?.({ code: 1006, reason: "Socket dropped" });

    await assert.rejects(
      async () => await pendingCall,
      /WebSocket closed/
    );
  });

  // --------------------------------------------------------------------------
  // Challenge 3: Stream Chunk Fragmentation (1-Byte Delivery)
  // --------------------------------------------------------------------------
  console.log("\n--- Challenge 3: Stream Fragmentation (1-Byte Delivery) ---");

  await test("reassembles complete frame when delivered 1 byte at a time", async () => {
    let wsInstance = null;
    class MockByteChunkWs {
      constructor() {
        this.readyState = 0;
        this.onopen = null;
        this.onmessage = null;
        this.onclose = null;
        this.onerror = null;
        wsInstance = this;
        setTimeout(() => {
          this.readyState = 1;
          this.onopen?.({});
        }, 5);
      }
      send(data) {
        const { frames } = splitFrames(new Uint8Array(data));
        for (const frame of frames) {
          if (frame.kind === Kind.Hello) {
            const h = encodeFrame(Kind.Hello, encodeHello(0x1234));
            // Deliver byte-by-byte
            setTimeout(() => {
              for (let i = 0; i < h.length; i++) {
                const singleByte = h.subarray(i, i + 1);
                this.onmessage?.({ data: singleByte.buffer });
              }
            }, 5);
          }
        }
      }
      close() {}
    }

    const client = new RA8RpcClient({ WebSocketClass: MockByteChunkWs, timeoutMs: 2000 });
    const hello = await client.connect("ws://mock.test:24880");
    assert.equal(hello.version, 1);
    assert.equal(hello.caps, 0x1234);
    client.disconnect();
  });

  // --------------------------------------------------------------------------
  // Challenge 4: Malformed Frame Handling
  // --------------------------------------------------------------------------
  console.log("\n--- Challenge 4: Malformed Frame / Garbage Handling ---");

  await test("splitFrames ignores garbage bytes less than 6 bytes without crashing", () => {
    const garbage = new Uint8Array([0xff, 0xfe, 0xfd]);
    const { frames, remainder } = splitFrames(garbage);
    assert.equal(frames.length, 0);
    assert.equal(remainder.length, 3);
  });

  await test("splitFrames does not overflow when length header exceeds buffer", () => {
    // Header says payload is 1000 bytes, but buffer only has 10 bytes
    const buf = new Uint8Array(16);
    const view = new DataView(buf.buffer);
    view.setUint32(0, 1000, true); // length = 1000
    view.setUint16(4, 2, true);    // kind = Request

    const { frames, remainder } = splitFrames(buf);
    assert.equal(frames.length, 0);
    assert.equal(remainder.length, 16);
  });

  // --------------------------------------------------------------------------
  // Challenge 5: Framebuffer & Dirty Rect Adversarial Inputs
  // --------------------------------------------------------------------------
  console.log("\n--- Challenge 5: Framebuffer & Dirty Rect Adversarial Inputs ---");

  await test("dirtyRectToRgba handles 0x0 empty rect gracefully", () => {
    const rect = {
      core: Core.Cpu0,
      x: 0,
      y: 0,
      width: 0,
      height: 0,
      virtualNs: 0n,
      pixels: new Uint8Array(0),
    };
    assert.equal(detectPixelFormat(rect), "grayscale");
    const rgba = dirtyRectToRgba(rect);
    assert.equal(rgba.length, 0);
  });

  await test("dirtyRectToRgba handles truncated pixel array without crashing", () => {
    const rect = {
      core: Core.Cpu0,
      x: 0,
      y: 0,
      width: 4,
      height: 4, // 16 pixels
      virtualNs: 0n,
      pixels: new Uint8Array([10, 20, 30]), // only 3 bytes provided!
    };
    const rgba = dirtyRectToRgba(rect);
    assert.equal(rgba.length, 16 * 4); // 64 bytes
    // Missing pixels should safely default to 0
    assert.equal(rgba[0], 10);
    assert.equal(rgba[4], 20);
    assert.equal(rgba[8], 30);
    assert.equal(rgba[12], 0); // 4th pixel safely 0
  });

  await test("dirtyRectToRgba converts 24-bit RGB and 32-bit RGBA correctly", () => {
    // RGB24: 1 pixel [255, 128, 64]
    const rect24 = {
      core: Core.Cpu0,
      x: 0,
      y: 0,
      width: 1,
      height: 1,
      virtualNs: 0n,
      pixels: new Uint8Array([255, 128, 64]),
    };
    assert.equal(detectPixelFormat(rect24), "rgb24");
    const rgba24 = dirtyRectToRgba(rect24);
    assert.deepEqual(Array.from(rgba24), [255, 128, 64, 255]);

    // RGBA32: 1 pixel [10, 20, 30, 40]
    const rect32 = {
      core: Core.Cpu0,
      x: 0,
      y: 0,
      width: 1,
      height: 1,
      virtualNs: 0n,
      pixels: new Uint8Array([10, 20, 30, 40]),
    };
    assert.equal(detectPixelFormat(rect32), "rgba32");
    const rgba32 = dirtyRectToRgba(rect32);
    assert.deepEqual(Array.from(rgba32), [10, 20, 30, 40]);
  });

  // --------------------------------------------------------------------------
  // Challenge 6: TypedEventEmitter Resilience
  // --------------------------------------------------------------------------
  console.log("\n--- Challenge 6: TypedEventEmitter Resilience ---");

  await test("listener error does not abort subsequent listener execution", () => {
    const emitter = new TypedEventEmitter();
    let secondCalled = false;

    emitter.on("hello", () => {
      throw new Error("Deliberate error in listener");
    });
    emitter.on("hello", () => {
      secondCalled = true;
    });

    emitter.emit("hello", { magic: 0, version: 1, caps: 0 });
    assert.equal(secondCalled, true, "Second listener should still be called");
  });

  await test("removing listener prevents invocation", () => {
    const emitter = new TypedEventEmitter();
    let count = 0;
    const fn = () => count++;

    emitter.on("open", fn);
    emitter.emit("open", undefined);
    assert.equal(count, 1);

    emitter.off("open", fn);
    emitter.emit("open", undefined);
    assert.equal(count, 1);
  });

  // --------------------------------------------------------------------------
  // Summary
  // --------------------------------------------------------------------------
  console.log(`\n=== Adversarial Challenge Results: ${passed} passed, ${failed} failed ===`);
  if (failed > 0) {
    process.exit(1);
  }
}

runAdversarialSuite();
