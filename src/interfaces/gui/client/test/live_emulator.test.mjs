import { spawn } from "node:child_process";
import { resolve } from "node:path";
import { RA8RpcClient, Core, Register } from "../dist/index.js";

async function runLiveTest() {
  console.log("=== EMPIRICAL TEST: Live RA8 Emulator WebSocket RPC ===");

  const port = 24892;
  const emulatorPath = resolve(import.meta.dirname, "../../../../../zig-out/bin/ra8_emulator");
  const fixtureElf = resolve(import.meta.dirname, "../../../../../tests/fixtures/gpio/blink.elf");

  console.log(`Starting emulator: ${emulatorPath} serve --listen tcp:127.0.0.1:${port} ${fixtureElf}`);
  const proc = spawn(emulatorPath, [
    "serve",
    "--listen",
    `tcp:127.0.0.1:${port}`,
    fixtureElf,
  ], {
    stdio: ["pipe", "pipe", "pipe"],
  });

  let serverStarted = false;
  proc.stdout.on("data", (data) => console.log(`[EMU stdout] ${data.toString().trim()}`));
  proc.stderr.on("data", (data) => {
    const text = data.toString();
    console.log(`[EMU stderr] ${text.trim()}`);
    if (text.includes("serve: listening on tcp:")) {
      serverStarted = true;
    }
  });

  proc.on("error", (err) => {
    console.error("Emulator failed to start:", err);
  });

  // Wait up to 5 seconds for server to start
  const start = Date.now();
  while (!serverStarted && Date.now() - start < 5000) {
    await new Promise((r) => setTimeout(r, 100));
  }

  if (!serverStarted) {
    proc.kill();
    throw new Error("Emulator server did not start in time");
  }

  console.log("Emulator server is listening. Connecting RA8RpcClient via WebSocket...");
  const client = new RA8RpcClient({ timeoutMs: 5000 });

  try {
    const hello = await client.connect(`ws://127.0.0.1:${port}`);
    console.log(`✓ WebSocket connected and handshook: magic=0x${hello.magic.toString(16)}, version=${hello.version}, caps=0x${hello.caps.toString(16)}`);

    // 1. Telemetry / Metrics (0x012E)
    const metrics = await client.getMetrics();
    console.log(`✓ getMetrics(): hostCpu=${metrics.hostCpuPercent}%, hostRss=${metrics.hostRssMb}MB, hostThreads=${metrics.hostThreads}, cpu0Load=${metrics.cpu0LoadPercent}%, cpu0RamUsed=${metrics.cpu0RamUsedBytes}`);
    if (typeof metrics.hostCpuPercent !== "number" || typeof metrics.cpu0LoadPercent !== "number") {
      throw new Error("Invalid metrics response structure");
    }

    // 2. Read Registers before step
    const regs1 = await client.readRegisters(Core.Cpu0);
    console.log(`✓ readRegisters() initial PC=0x${regs1.pc?.toString(16)}, SP=0x${regs1.sp?.toString(16)}`);

    // 3. Step execution
    const stepAck = await client.step(Core.Cpu0);
    console.log(`✓ step() acknowledged: ${stepAck}`);

    // 4. Read Registers after step
    const regs2 = await client.readRegisters(Core.Cpu0);
    console.log(`✓ readRegisters() after step: PC=0x${regs2.pc?.toString(16)}`);

    // 5. Read Memory at PC (0x02000000)
    const mem = await client.readMemory(Core.Cpu0, 0x02000000, 16);
    console.log(`✓ readMemory(0x00000000, 16): ${Array.from(mem).map(b => b.toString(16).padStart(2, "0")).join(" ")}`);
    if (mem.length !== 16) {
      throw new Error(`Expected 16 bytes memory, got ${mem.length}`);
    }

    // 6. Disconnect
    client.disconnect();
    console.log("✓ Client disconnected cleanly");

  } finally {
    proc.kill("SIGTERM");
    console.log("Emulator process terminated.");
  }
}

runLiveTest().then(
  () => {
    console.log("\n>>> LIVE EMULATOR WEBSOCKET RPC TEST PASSED! <<<\n");
    process.exit(0);
  },
  (err) => {
    console.error("\n>>> LIVE EMULATOR WEBSOCKET RPC TEST FAILED:", err);
    process.exit(1);
  }
);
