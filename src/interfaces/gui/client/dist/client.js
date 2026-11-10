/**
 * RA8 Emulator Typed WebSocket RPC Client
 *
 * Implements RA8RpcClient for seamless browser and Node.js communication with
 * ra8-emulator RFC 6455 transport bridge. Zero runtime dependencies.
 */
import { Kind, ErrorCode, Method, Topic, Core, Register, RunMode, Direction, PROTOCOL_MAGIC, PROTOCOL_VERSION, } from "./types.js";
import { encodeHello, decodeHello, decodeFault, encodeRequest, decodeResponse, decodeEvent, encodeFrame, splitFrames, encodeCoreOnly, encodeRun, encodeReadRegister, encodeWriteRegister, encodeReadMemory, decodeMemory, encodeWriteMemory, encodeSubscription, encodePoint, encodePointId, encodeAdvance, encodeSetSpeed, encodeScheduleInput, encodeConsoleInput, encodeDisasmAsk, decodeDisasmReply, decodeStackReport, encodePeriphAsk, encodeFoldedAsk, decodeTextSlice, decodeTraceEvent, decodeTransportEvent, decodeBranchList, encodeBranchSwitch, encodeBranchDelete, encodeBranchConfirmFork, decodeForkStatus, encodeSeek, encodePlayArgs, encodeNavQueryArgs, decodeNavQueryResult, encodeMarkerSetArgs, decodeFrameStatusResult, encodeDiffArgs, decodeDiff, decodeU32, decodeU64, decodeAck, decodeStopped, decodeUart, decodeSessionEvent, decodeBoardParts, decodeBacktrace, decodeDirtyRect, decodeMetricsReport, } from "./codec.js";
/** Lightweight, zero-dependency typed event emitter */
export class TypedEventEmitter {
    listeners = new Map();
    on(event, listener) {
        let set = this.listeners.get(event);
        if (!set) {
            set = new Set();
            this.listeners.set(event, set);
        }
        set.add(listener);
        return this;
    }
    off(event, listener) {
        const set = this.listeners.get(event);
        if (set) {
            set.delete(listener);
            if (set.size === 0)
                this.listeners.delete(event);
        }
        return this;
    }
    emit(event, data) {
        const set = this.listeners.get(event);
        if (!set || set.size === 0)
            return false;
        for (const listener of Array.from(set)) {
            try {
                listener(data);
            }
            catch (err) {
                console.error(`Error in event listener for ${String(event)}:`, err);
            }
        }
        return true;
    }
    removeAllListeners(event) {
        if (event) {
            this.listeners.delete(event);
        }
        else {
            this.listeners.clear();
        }
        return this;
    }
}
/**
 * RA8 Emulator RPC Client over WebSocket
 */
export class RA8RpcClient extends TypedEventEmitter {
    ws = null;
    nextId = 1;
    pending = new Map();
    rxBuffer = new Uint8Array(0);
    handshakePromise = null;
    serverHello = null;
    connectTimer = null;
    defaultTimeoutMs;
    clientCaps;
    wsClass;
    constructor(options = {}) {
        super();
        this.defaultTimeoutMs = options.timeoutMs ?? 10000;
        this.clientCaps = options.caps ?? 0x0000ffff;
        // Auto-detect global WebSocket (browser or Node.js 22+)
        this.wsClass =
            options.WebSocketClass ??
                (typeof WebSocket !== "undefined"
                    ? WebSocket
                    : globalThis.WebSocket);
        if (!this.wsClass) {
            throw new Error("WebSocket implementation not found. In older Node.js, pass WebSocketClass in options.");
        }
    }
    /** Current connection state */
    get isConnected() {
        return this.ws !== null && this.ws.readyState === 1 && this.serverHello !== null;
    }
    /** Negotiated server capabilities */
    get serverCaps() {
        return this.serverHello ? this.serverHello.caps : null;
    }
    /**
     * Connect to RA8 emulator WebSocket RPC endpoint
     */
    async connect(url = "ws://127.0.0.1:24880") {
        if (this.isConnected) {
            return this.serverHello;
        }
        return new Promise((resolve, reject) => {
            try {
                this.ws = new this.wsClass(url);
                this.ws.binaryType = "arraybuffer";
            }
            catch (err) {
                return reject(err);
            }
            this.handshakePromise = { resolve, reject };
            if (this.connectTimer) {
                clearTimeout(this.connectTimer);
                this.connectTimer = null;
            }
            this.connectTimer = setTimeout(() => {
                this.connectTimer = null;
                if (this.handshakePromise) {
                    this.handshakePromise.reject(new Error(`Connection handshake timed out after ${this.defaultTimeoutMs}ms`));
                    this.handshakePromise = null;
                    this.disconnect();
                }
            }, this.defaultTimeoutMs);
            this.ws.onopen = () => {
                // Step 1: Send client Hello frame
                const helloPayload = encodeHello(this.clientCaps);
                const helloFrame = encodeFrame(Kind.Hello, helloPayload);
                this.sendRaw(helloFrame);
                this.emit("open", undefined);
            };
            this.ws.onmessage = (event) => {
                const raw = event.data;
                const chunk = raw instanceof ArrayBuffer
                    ? new Uint8Array(raw)
                    : new Uint8Array(raw.buffer, raw.byteOffset, raw.byteLength);
                this.onData(chunk);
            };
            this.ws.onclose = (event) => {
                if (this.connectTimer) {
                    clearTimeout(this.connectTimer);
                    this.connectTimer = null;
                }
                this.serverHello = null;
                this.cleanupPending(new Error(`WebSocket closed (${event.code}): ${event.reason}`));
                if (this.handshakePromise) {
                    this.handshakePromise.reject(new Error(`WebSocket closed before handshake: ${event.code} ${event.reason}`));
                    this.handshakePromise = null;
                }
                this.emit("close", { code: event.code, reason: event.reason });
            };
            this.ws.onerror = (err) => {
                if (this.connectTimer) {
                    clearTimeout(this.connectTimer);
                    this.connectTimer = null;
                }
                const error = err instanceof Error ? err : new Error(`WebSocket error: ${String(err)}`);
                this.emit("error", error);
                if (this.handshakePromise) {
                    this.handshakePromise.reject(error);
                    this.handshakePromise = null;
                }
            };
        });
    }
    /** Disconnect from the WebSocket server */
    disconnect() {
        if (this.connectTimer) {
            clearTimeout(this.connectTimer);
            this.connectTimer = null;
        }
        if (this.ws) {
            try {
                this.ws.close();
            }
            catch {
                // ignore
            }
            this.ws = null;
        }
        this.serverHello = null;
        this.cleanupPending(new Error("Client disconnected"));
    }
    /** Low-level RPC method invocation */
    async call(method, args, timeoutMs = this.defaultTimeoutMs) {
        if (!this.isConnected) {
            throw new Error("RPC client is not connected");
        }
        const id = this.nextId++;
        const reqPayload = encodeRequest(id, method, args);
        const frame = encodeFrame(Kind.Request, reqPayload);
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                this.pending.delete(id);
                reject(new Error(`RPC call method 0x${method.toString(16)} (id ${id}) timed out`));
            }, timeoutMs);
            this.pending.set(id, { resolve, reject, timer });
            this.sendRaw(frame);
        });
    }
    /* ------------------------------------------------------------------------ */
    /* High-Level Client Operations                                             */
    /* ------------------------------------------------------------------------ */
    /** Step single virtual instruction */
    async step(core = Core.Cpu0) {
        const resp = await this.call(Method.Step, encodeCoreOnly(core));
        return decodeAck(resp).accepted !== 0;
    }
    /** Run simulation */
    async run(core = Core.Cpu0, mode = RunMode.Run, budget = 0n) {
        const resp = await this.call(Method.Run, encodeRun(core, mode, budget));
        return decodeAck(resp).accepted !== 0;
    }
    /** Pause simulation */
    async pause(core = Core.Cpu0) {
        const resp = await this.call(Method.Pause, encodeCoreOnly(core));
        return decodeAck(resp).accepted !== 0;
    }
    /** Read single CPU register */
    async readRegister(core, register) {
        const resp = await this.call(Method.ReadRegister, encodeReadRegister(core, register));
        return decodeU32(resp);
    }
    /** Read common core registers */
    async readRegisters(core = Core.Cpu0) {
        const common = [
            { name: "pc", reg: Register.Pc },
            { name: "sp", reg: Register.Sp },
            { name: "lr", reg: Register.Lr },
            { name: "r0", reg: Register.R0 },
            { name: "r1", reg: Register.R1 },
            { name: "r2", reg: Register.R2 },
            { name: "r3", reg: Register.R3 },
            { name: "r4", reg: Register.R4 },
            { name: "r5", reg: Register.R5 },
            { name: "r6", reg: Register.R6 },
            { name: "r7", reg: Register.R7 },
            { name: "r8", reg: Register.R8 },
            { name: "r9", reg: Register.R9 },
            { name: "r10", reg: Register.R10 },
            { name: "r11", reg: Register.R11 },
            { name: "r12", reg: Register.R12 },
            { name: "xpsr", reg: Register.Xpsr },
            { name: "msp", reg: Register.Msp },
            { name: "psp", reg: Register.Psp },
        ];
        const results = {};
        for (const item of common) {
            results[item.name] = await this.readRegister(core, item.reg);
        }
        return results;
    }
    /** Write value to CPU register */
    async writeRegister(core, register, value) {
        const resp = await this.call(Method.WriteRegister, encodeWriteRegister(core, register, value));
        return decodeAck(resp).accepted !== 0;
    }
    /** Read guest memory slice */
    async readMemory(core, address, length) {
        const resp = await this.call(Method.ReadMemory, encodeReadMemory(core, address, length));
        return decodeMemory(resp);
    }
    /** Write bytes to guest memory */
    async writeMemory(core, address, bytes) {
        const resp = await this.call(Method.WriteMemory, encodeWriteMemory(core, address, bytes));
        return decodeAck(resp).accepted !== 0;
    }
    /** Get host and guest device telemetry metrics */
    async getMetrics() {
        const resp = await this.call(Method.Metrics, encodeCoreOnly(Core.Cpu0));
        return decodeMetricsReport(resp);
    }
    /** Subscribe core to event topic */
    async subscribe(core, topic, rate = 0) {
        const resp = await this.call(Method.Subscribe, encodeSubscription(core, topic, rate));
        return decodeAck(resp).accepted !== 0;
    }
    /** Unsubscribe core from event topic */
    async unsubscribe(core, topic) {
        const resp = await this.call(Method.Unsubscribe, encodeSubscription(core, topic, 0));
        return decodeAck(resp).accepted !== 0;
    }
    /** Set instruction breakpoint and return its assigned breakpoint ID */
    async setBreakpointId(core, address) {
        const resp = await this.call(Method.SetBreakpoint, encodePoint(core, address));
        return resp.length >= 4 ? decodeU32(resp) : (decodeAck(resp).accepted !== 0 ? 1 : 0);
    }
    /** Set instruction breakpoint */
    async setBreakpoint(core, address) {
        const resp = await this.call(Method.SetBreakpoint, encodePoint(core, address));
        return resp.length >= 4 ? true : decodeAck(resp).accepted !== 0;
    }
    /** Clear instruction breakpoint by assigned breakpoint ID */
    async clearBreakpointById(core, id) {
        const resp = await this.call(Method.ClearBreakpoint, encodePointId(core, id));
        return decodeAck(resp).accepted !== 0;
    }
    /** Clear instruction breakpoint */
    async clearBreakpoint(core, idOrAddress) {
        const resp = await this.call(Method.ClearBreakpoint, encodePointId(core, idOrAddress));
        return decodeAck(resp).accepted !== 0;
    }
    /** Authoritative backend instruction disassembly + symbol entry labels */
    async disassemble(core = Core.Cpu0, options = {}) {
        const resp = await this.call(Method.Disasm, encodeDisasmAsk({
            core,
            address: options.address ?? 0,
            count: options.count ?? 24,
            usePc: options.usePc ?? options.address === undefined,
        }));
        return decodeDisasmReply(resp);
    }
    /** Query current virtual board time in nanoseconds */
    async now(core = Core.Cpu0) {
        const resp = await this.call(Method.Now, encodeCoreOnly(core));
        return decodeU64(resp);
    }
    /** Advance simulation by virtual nanoseconds */
    async advance(core, ns) {
        const resp = await this.call(Method.Advance, encodeAdvance(core, ns));
        return decodeAck(resp).accepted !== 0;
    }
    /** Set emulation pacing speed (0 = unthrottled) */
    async setSpeed(core = Core.Cpu0, milli = 0n) {
        const resp = await this.call(Method.SetSpeed, encodeSetSpeed(core, milli));
        return decodeAck(resp).accepted !== 0;
    }
    /** Get served board front-panel profile, LEDs, and switches */
    async getBoardParts() {
        const resp = await this.call(Method.BoardParts, encodeCoreOnly(Core.Cpu0));
        return decodeBoardParts(resp);
    }
    /** Get call stack backtrace for core */
    async getBacktrace(core = Core.Cpu0) {
        const resp = await this.call(Method.Backtrace, encodeCoreOnly(core));
        return decodeBacktrace(resp);
    }
    /** Get MSP/PSP stack pointers, low watermarks, and overflow count */
    async getStackReport(core = Core.Cpu0) {
        const resp = await this.call(Method.Stack, encodeCoreOnly(core));
        return decodeStackReport(resp);
    }
    /** List peripheral blocks (when block is empty) or inspect a block's registers */
    async getPeriph(core = Core.Cpu0, block = "", json = false) {
        const resp = await this.call(Method.Periph, encodePeriphAsk(core, block, json));
        return decodeTextSlice(resp);
    }
    /** List fitted off-chip parts (`MODEL@ENDPOINT` lines) */
    async getListParts(core = Core.Cpu0) {
        const resp = await this.call(Method.ListParts, encodeCoreOnly(core));
        const text = decodeTextSlice(resp).trim();
        return text.length > 0 ? text.split("\n").filter((l) => l.trim().length > 0) : [];
    }
    /** Sampled call stacks folded over [fromNs, toNs) */
    async getFolded(core = Core.Cpu0, thread = 0xffffffff, fromNs = 0n, toNs = 0xffffffffffffffffn) {
        const resp = await this.call(Method.Folded, encodeFoldedAsk(core, thread, fromNs, toNs));
        return decodeTextSlice(resp);
    }
    /** List time-travel execution branches in the history DAG */
    async getBranches() {
        const resp = await this.call(Method.BranchList, encodeCoreOnly(Core.Cpu0));
        return decodeBranchList(resp);
    }
    /** Switch active execution branch in the history DAG */
    async switchBranch(branch) {
        const resp = await this.call(Method.BranchSwitch, encodeBranchSwitch(branch));
        return decodeAck(resp).accepted !== 0;
    }
    /** Delete a non-live execution branch */
    async deleteBranch(branch, confirm = false) {
        const resp = await this.call(Method.BranchDelete, encodeBranchDelete(branch, confirm));
        return decodeAck(resp).accepted !== 0;
    }
    /** Confirm a pending fork after historical state mutation */
    async confirmFork(confirm = true) {
        const resp = await this.call(Method.BranchConfirmFork, encodeBranchConfirmFork(confirm));
        return decodeAck(resp).accepted !== 0;
    }
    /** Cancel a pending fork */
    async cancelFork() {
        const resp = await this.call(Method.BranchCancelFork, new Uint8Array(0));
        return decodeAck(resp).accepted !== 0;
    }
    /** Check whether a mutation fork is pending confirmation */
    async getForkStatus() {
        const resp = await this.call(Method.BranchStatus, encodeCoreOnly(Core.Cpu0));
        return decodeForkStatus(resp);
    }
    /** Seek to a virtual time, cycle, frame, or bookmark target */
    async seek(target) {
        const resp = await this.call(Method.Seek, encodeSeek(target));
        return decodeAck(resp).accepted !== 0;
    }
    /** Reverse-continue backwards to previous breakpoint or start of history */
    async reverseContinue(core = Core.Cpu0) {
        const resp = await this.call(Method.Rcont, encodeCoreOnly(core));
        return decodeAck(resp).accepted !== 0;
    }
    /** Play recorded history forward or backward */
    async play(dir = Direction.Fwd, speedMilli = 1000n) {
        const resp = await this.call(Method.Play, encodePlayArgs({ dir, speedMilli }));
        return decodeAck(resp).accepted !== 0;
    }
    /** Query frame, iteration, marker, RTOS, or ISR index in recorded history */
    async navQuery(args) {
        const resp = await this.call(Method.NavQuery, encodeNavQueryArgs(args));
        return decodeNavQueryResult(resp);
    }
    /** Set a named history marker on a symbol or hex address */
    async setMarker(name, place) {
        const resp = await this.call(Method.MarkerSet, encodeMarkerSetArgs(name, place));
        return decodeAck(resp).accepted !== 0;
    }
    /** Query rewind pipeline RAM/disk frame accounting */
    async getFrameStatus() {
        const resp = await this.call(Method.FrameStatus, encodeCoreOnly(Core.Cpu0));
        return decodeFrameStatusResult(resp);
    }
    /** Compute architectural register, memory page, and peripheral state diff between two points */
    async getDiff(a, b) {
        const resp = await this.call(Method.Diff, encodeDiffArgs(a, b));
        return decodeDiff(resp);
    }
    /** Injected touch or button input to guest firmware */
    async sendInput(args) {
        const resp = await this.call(Method.Input, encodeScheduleInput(args));
        return decodeAck(resp).accepted !== 0;
    }
    /** Send bytes to virtual console UART */
    async sendConsoleInput(core, bytes) {
        const resp = await this.call(Method.ConsoleInput, encodeConsoleInput(core, bytes));
        return decodeAck(resp).accepted !== 0;
    }
    /* ------------------------------------------------------------------------ */
    /* Internal Stream and Packet Processing                                    */
    /* ------------------------------------------------------------------------ */
    sendRaw(data) {
        if (!this.ws || this.ws.readyState !== 1) {
            throw new Error("Cannot send frame: WebSocket is not open");
        }
        this.ws.send(data);
    }
    onData(chunk) {
        if (this.rxBuffer.length === 0) {
            this.rxBuffer = chunk;
        }
        else {
            const merged = new Uint8Array(this.rxBuffer.length + chunk.length);
            merged.set(this.rxBuffer, 0);
            merged.set(chunk, this.rxBuffer.length);
            this.rxBuffer = merged;
        }
        const { frames, remainder } = splitFrames(this.rxBuffer);
        this.rxBuffer = remainder;
        for (const frame of frames) {
            this.processFrame(frame.kind, frame.payload);
        }
    }
    processFrame(kind, payload) {
        switch (kind) {
            case Kind.Hello: {
                if (this.connectTimer) {
                    clearTimeout(this.connectTimer);
                    this.connectTimer = null;
                }
                const hello = decodeHello(payload);
                if (hello.magic !== PROTOCOL_MAGIC || hello.version !== PROTOCOL_VERSION) {
                    const err = new Error(`Incompatible RPC peer: magic 0x${hello.magic.toString(16)}, version ${hello.version}`);
                    if (this.handshakePromise) {
                        this.handshakePromise.reject(err);
                        this.handshakePromise = null;
                    }
                    this.disconnect();
                    return;
                }
                this.serverHello = hello;
                if (this.handshakePromise) {
                    this.handshakePromise.resolve(hello);
                    this.handshakePromise = null;
                }
                this.emit("hello", hello);
                break;
            }
            case Kind.Fault: {
                const fault = decodeFault(payload);
                const err = new Error(`RPC fault code ${fault.code} (version ${fault.version})`);
                this.emit("error", err);
                break;
            }
            case Kind.Response: {
                const resp = decodeResponse(payload);
                const pending = this.pending.get(resp.id);
                if (pending) {
                    this.pending.delete(resp.id);
                    clearTimeout(pending.timer);
                    if (resp.ok) {
                        pending.resolve(resp.payload);
                    }
                    else {
                        pending.reject(new Error(`RPC error code ${resp.code ?? ErrorCode.Failed} for call id ${resp.id}`));
                    }
                }
                break;
            }
            case Kind.Event: {
                const event = decodeEvent(payload);
                this.emit("event", event);
                this.dispatchTopicEvent(event.topic, event.payload);
                break;
            }
            default:
                console.warn(`Unrecognized frame kind: ${kind}`);
                break;
        }
    }
    dispatchTopicEvent(topic, payload) {
        try {
            switch (topic) {
                case Topic.Stop:
                    this.emit("stop", decodeStopped(payload));
                    break;
                case Topic.Uart:
                    this.emit("uart", decodeUart(payload));
                    break;
                case Topic.LcdDirty:
                    this.emit("lcd_dirty", decodeDirtyRect(payload));
                    break;
                case Topic.Trace:
                    this.emit("trace", decodeTraceEvent(payload));
                    break;
                case Topic.Session:
                    this.emit("session", decodeSessionEvent(payload));
                    break;
                case Topic.Transport:
                    this.emit("transport", decodeTransportEvent(payload));
                    break;
                default:
                    break;
            }
        }
        catch (err) {
            console.error(`Error decoding event topic 0x${topic.toString(16)}:`, err);
        }
    }
    cleanupPending(err) {
        for (const pending of this.pending.values()) {
            clearTimeout(pending.timer);
            pending.reject(err);
        }
        this.pending.clear();
    }
}
//# sourceMappingURL=client.js.map