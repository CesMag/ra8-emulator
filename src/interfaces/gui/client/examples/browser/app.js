/**
 * Interactive Browser RPC App
 *
 * Connects to RA8 emulator WebSocket bridge, renders live LCD dirty rectangles,
 * updates telemetry metrics, inspects registers, and controls execution.
 */

import {
  RA8RpcClient,
  Core,
  Register,
  RunMode,
  Topic,
  FramebufferRenderer,
} from "../../dist/index.js";

// DOM Elements
const statusBadge = document.getElementById("statusBadge");
const wsUrlInput = document.getElementById("wsUrlInput");
const btnConnect = document.getElementById("btnConnect");
const btnDisconnect = document.getElementById("btnDisconnect");

const coreSelect = document.getElementById("coreSelect");
const btnStep = document.getElementById("btnStep");
const btnRun = document.getElementById("btnRun");
const btnPause = document.getElementById("btnPause");
const btnReset = document.getElementById("btnReset");
const bkptAddress = document.getElementById("bkptAddress");
const btnSetBkpt = document.getElementById("btnSetBkpt");

const mHostCpu = document.getElementById("mHostCpu");
const mHostRss = document.getElementById("mHostRss");
const mHostThreads = document.getElementById("mHostThreads");
const mCpu0Load = document.getElementById("mCpu0Load");
const mCpu0Ram = document.getElementById("mCpu0Ram");
const mCpu0Pinned = document.getElementById("mCpu0Pinned");
const btnRefreshMetrics = document.getElementById("btnRefreshMetrics");
const autoMetricsCheckbox = document.getElementById("autoMetrics");

const lcdCanvas = document.getElementById("lcdCanvas");
const lcdMetrics = document.getElementById("lcdMetrics");
const btnSubscribeLcd = document.getElementById("btnSubscribeLcd");
const btnUnsubscribeLcd = document.getElementById("btnUnsubscribeLcd");
const btnClearLcd = document.getElementById("btnClearLcd");

const btnReadRegs = document.getElementById("btnReadRegs");
const consoleLog = document.getElementById("consoleLog");
const btnClearLog = document.getElementById("btnClearLog");

let client = null;
let renderer = null;
let metricsInterval = null;

function log(msg) {
  const time = new Date().toLocaleTimeString();
  consoleLog.textContent += `[${time}] ${msg}\n`;
  consoleLog.scrollTop = consoleLog.scrollHeight;
}

function setStatus(status, text) {
  statusBadge.className = `badge badge-${status}`;
  statusBadge.textContent = text;
}

function getSelectedCore() {
  return parseInt(coreSelect.value, 10) === 1 ? Core.Cpu1 : Core.Cpu0;
}

// Initialize Framebuffer Canvas Renderer
if (lcdCanvas) {
  renderer = new FramebufferRenderer(lcdCanvas, { defaultWidth: 480, defaultHeight: 272 });
}

// Connect Handler
btnConnect.addEventListener("click", async () => {
  const url = wsUrlInput.value.trim() || "ws://127.0.0.1:24880";
  log(`Connecting to ${url}...`);
  setStatus("connecting", "Connecting...");

  try {
    client = new RA8RpcClient({ timeoutMs: 8000 });

    client.on("open", () => {
      log("WebSocket transport link established");
    });

    client.on("hello", (hello) => {
      log(`Handshake OK: protocol v${hello.version}, server caps 0x${hello.caps.toString(16)}`);
      setStatus("connected", "Connected");
      btnConnect.disabled = true;
      btnDisconnect.disabled = false;
      refreshMetrics();
      refreshRegisters();
    });

    client.on("close", (e) => {
      log(`WebSocket closed (code ${e.code}): ${e.reason || "clean"}`);
      setStatus("disconnected", "Disconnected");
      btnConnect.disabled = false;
      btnDisconnect.disabled = true;
      if (metricsInterval) clearInterval(metricsInterval);
    });

    client.on("error", (err) => {
      log(`Transport error: ${err.message}`);
    });

    client.on("stop", (stopped) => {
      log(`CPU stopped: core=${stopped.core}, reason=${stopped.reason}, PC=0x${stopped.address.toString(16)}`);
      refreshRegisters();
    });

    client.on("uart", (uart) => {
      const text = new TextDecoder().decode(uart.bytes);
      log(`[UART ch${uart.channel}] ${text}`);
    });

    client.on("lcd_dirty", (rect) => {
      if (renderer) {
        renderer.render(rect);
        lcdMetrics.textContent = `${renderer.currentFps} FPS | ${rect.width}x${rect.height} dirty`;
      }
    });

    await client.connect(url);

    // Setup auto metrics poll
    if (metricsInterval) clearInterval(metricsInterval);
    metricsInterval = setInterval(() => {
      if (autoMetricsCheckbox.checked && client && client.isConnected) {
        refreshMetrics();
      }
    }, 1000);

  } catch (err) {
    log(`Connection failed: ${err.message}`);
    setStatus("disconnected", "Failed");
    btnConnect.disabled = false;
    btnDisconnect.disabled = true;
  }
});

// Disconnect Handler
btnDisconnect.addEventListener("click", () => {
  if (client) {
    client.disconnect();
    client = null;
  }
  if (metricsInterval) clearInterval(metricsInterval);
  setStatus("disconnected", "Disconnected");
  btnConnect.disabled = false;
  btnDisconnect.disabled = true;
  log("Disconnected by user");
});

// Controls
btnStep.addEventListener("click", async () => {
  if (!client || !client.isConnected) return;
  try {
    const ok = await client.step(getSelectedCore());
    log(`Step: ${ok ? "accepted" : "refused"}`);
  } catch (err) {
    log(`Step error: ${err.message}`);
  }
});

btnRun.addEventListener("click", async () => {
  if (!client || !client.isConnected) return;
  try {
    const ok = await client.run(getSelectedCore(), RunMode.Run);
    log(`Run: ${ok ? "accepted" : "refused"}`);
  } catch (err) {
    log(`Run error: ${err.message}`);
  }
});

btnPause.addEventListener("click", async () => {
  if (!client || !client.isConnected) return;
  try {
    const ok = await client.pause(getSelectedCore());
    log(`Pause: ${ok ? "accepted" : "refused"}`);
  } catch (err) {
    log(`Pause error: ${err.message}`);
  }
});

btnSetBkpt.addEventListener("click", async () => {
  if (!client || !client.isConnected) return;
  const addr = parseInt(bkptAddress.value, 16);
  if (isNaN(addr)) {
    log("Invalid hex breakpoint address");
    return;
  }
  try {
    const ok = await client.setBreakpoint(getSelectedCore(), addr);
    log(`Set breakpoint at 0x${addr.toString(16)}: ${ok ? "OK" : "failed"}`);
  } catch (err) {
    log(`Set breakpoint error: ${err.message}`);
  }
});

btnReset.addEventListener("click", async () => {
  if (!client || !client.isConnected) return;
  const addr = parseInt(bkptAddress.value, 16);
  if (isNaN(addr)) {
    log("Invalid hex breakpoint address to clear");
    return;
  }
  try {
    const ok = await client.clearBreakpoint(getSelectedCore(), addr);
    log(`Clear breakpoint at 0x${addr.toString(16)}: ${ok ? "OK" : "failed"}`);
  } catch (err) {
    log(`Clear breakpoint error: ${err.message}`);
  }
});

// Metrics
async function refreshMetrics() {
  if (!client || !client.isConnected) return;
  try {
    const m = await client.getMetrics();
    mHostCpu.textContent = `${m.hostCpuPercent}%`;
    mHostRss.textContent = `${m.hostRssMb} MB`;
    mHostThreads.textContent = `${m.hostThreads}`;
    mCpu0Load.textContent = `${m.cpu0LoadPercent}%`;
    mCpu0Ram.textContent = `${Math.round(m.cpu0RamUsedBytes / 1024)} / ${Math.round(m.cpu0RamTotalBytes / 1024)} KB`;
    mCpu0Pinned.textContent = m.cpu0Pinned ? "Yes" : "No";
  } catch (err) {
    // silent or log
  }
}
btnRefreshMetrics.addEventListener("click", refreshMetrics);

// Registers
async function refreshRegisters() {
  if (!client || !client.isConnected) return;
  const core = getSelectedCore();
  const regs = [
    { name: "pc", reg: Register.Pc },
    { name: "sp", reg: Register.Sp },
    { name: "lr", reg: Register.Lr },
    { name: "r0", reg: Register.R0 },
    { name: "r1", reg: Register.R1 },
    { name: "r2", reg: Register.R2 },
    { name: "r3", reg: Register.R3 },
    { name: "xpsr", reg: Register.Xpsr },
  ];

  for (const item of regs) {
    try {
      const val = await client.readRegister(core, item.reg);
      const cell = document.getElementById(`reg_${item.name}`);
      if (cell) {
        cell.textContent = `0x${val.toString(16).padStart(8, "0").toUpperCase()}`;
        if (cell.nextElementSibling) {
          cell.nextElementSibling.textContent = `${val}`;
        }
      }
    } catch {
      // ignore
    }
  }
}
btnReadRegs.addEventListener("click", refreshRegisters);

// LCD Subscription
btnSubscribeLcd.addEventListener("click", async () => {
  if (!client || !client.isConnected) return;
  try {
    const ok = await client.subscribe(getSelectedCore(), Topic.LcdDirty, 30);
    log(`Subscribe LCD (30 FPS): ${ok ? "OK" : "refused"}`);
  } catch (err) {
    log(`Subscribe LCD error: ${err.message}`);
  }
});

btnUnsubscribeLcd.addEventListener("click", async () => {
  if (!client || !client.isConnected) return;
  try {
    const ok = await client.unsubscribe(getSelectedCore(), Topic.LcdDirty);
    log(`Unsubscribe LCD: ${ok ? "OK" : "refused"}`);
  } catch (err) {
    log(`Unsubscribe LCD error: ${err.message}`);
  }
});

btnClearLcd.addEventListener("click", () => {
  if (renderer) renderer.clear("#000000");
});

btnClearLog.addEventListener("click", () => {
  consoleLog.textContent = "";
});
