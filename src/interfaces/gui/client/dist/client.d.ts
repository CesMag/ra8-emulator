/**
 * RA8 Emulator Typed WebSocket RPC Client
 *
 * Implements RA8RpcClient for seamless browser and Node.js communication with
 * ra8-emulator RFC 6455 transport bridge. Zero runtime dependencies.
 */
import { Method, Topic, Core, Register, RunMode, Hello, MetricsReport, DirtyRect, Stopped, UartEvent, SessionEvent, TransportEvent, TraceEvent, RpcEventEnvelope, BoardParts, Backtrace, DisasmReply, StackReport, BranchItem, ForkStatus, Direction, NavQueryArgs, NavQueryResult, FrameStatusResult, DecodedDiff, ScheduleInputArgs } from "./types.js";
export type EventListener<T = any> = (data: T) => void;
/** Client events map */
export interface ClientEventMap {
    open: void;
    close: {
        code: number;
        reason: string;
    };
    error: Error;
    hello: Hello;
    event: RpcEventEnvelope;
    stop: Stopped;
    uart: UartEvent;
    lcd_dirty: DirtyRect;
    trace: TraceEvent;
    session: SessionEvent;
    transport: TransportEvent;
}
/** Lightweight, zero-dependency typed event emitter */
export declare class TypedEventEmitter {
    private readonly listeners;
    on<K extends keyof ClientEventMap>(event: K, listener: (data: ClientEventMap[K]) => void): this;
    off<K extends keyof ClientEventMap>(event: K, listener: (data: ClientEventMap[K]) => void): this;
    emit<K extends keyof ClientEventMap>(event: K, data: ClientEventMap[K]): boolean;
    removeAllListeners(event?: keyof ClientEventMap): this;
}
export interface ClientOptions {
    timeoutMs?: number;
    caps?: number;
    WebSocketClass?: any;
}
/**
 * RA8 Emulator RPC Client over WebSocket
 */
export declare class RA8RpcClient extends TypedEventEmitter {
    private ws;
    private nextId;
    private readonly pending;
    private rxBuffer;
    private handshakePromise;
    private serverHello;
    private connectTimer;
    readonly defaultTimeoutMs: number;
    readonly clientCaps: number;
    private readonly wsClass;
    constructor(options?: ClientOptions);
    /** Current connection state */
    get isConnected(): boolean;
    /** Negotiated server capabilities */
    get serverCaps(): number | null;
    /**
     * Connect to RA8 emulator WebSocket RPC endpoint
     */
    connect(url?: string): Promise<Hello>;
    /** Disconnect from the WebSocket server */
    disconnect(): void;
    /** Low-level RPC method invocation */
    call(method: Method | number, args?: Uint8Array, timeoutMs?: number): Promise<Uint8Array>;
    /** Step single virtual instruction */
    step(core?: Core): Promise<boolean>;
    /** Run simulation */
    run(core?: Core, mode?: RunMode, budget?: bigint): Promise<boolean>;
    /** Pause simulation */
    pause(core?: Core): Promise<boolean>;
    /** Read single CPU register */
    readRegister(core: Core, register: Register): Promise<number>;
    /** Read common core registers */
    readRegisters(core?: Core): Promise<Record<string, number>>;
    /** Write value to CPU register */
    writeRegister(core: Core, register: Register, value: number): Promise<boolean>;
    /** Read guest memory slice */
    readMemory(core: Core, address: number, length: number): Promise<Uint8Array>;
    /** Write bytes to guest memory */
    writeMemory(core: Core, address: number, bytes: Uint8Array): Promise<boolean>;
    /** Get host and guest device telemetry metrics */
    getMetrics(): Promise<MetricsReport>;
    /** Subscribe core to event topic */
    subscribe(core: Core, topic: Topic, rate?: number): Promise<boolean>;
    /** Unsubscribe core from event topic */
    unsubscribe(core: Core, topic: Topic): Promise<boolean>;
    /** Set instruction breakpoint and return its assigned breakpoint ID */
    setBreakpointId(core: Core, address: number): Promise<number>;
    /** Set instruction breakpoint */
    setBreakpoint(core: Core, address: number): Promise<boolean>;
    /** Clear instruction breakpoint by assigned breakpoint ID */
    clearBreakpointById(core: Core, id: number): Promise<boolean>;
    /** Clear instruction breakpoint */
    clearBreakpoint(core: Core, idOrAddress: number): Promise<boolean>;
    /** Authoritative backend instruction disassembly + symbol entry labels */
    disassemble(core?: Core, options?: {
        address?: number;
        count?: number;
        usePc?: boolean;
    }): Promise<DisasmReply>;
    /** Query current virtual board time in nanoseconds */
    now(core?: Core): Promise<bigint>;
    /** Advance simulation by virtual nanoseconds */
    advance(core: Core, ns: bigint): Promise<boolean>;
    /** Set emulation pacing speed (0 = unthrottled) */
    setSpeed(core?: Core, milli?: bigint | number): Promise<boolean>;
    /** Get served board front-panel profile, LEDs, and switches */
    getBoardParts(): Promise<BoardParts>;
    /** Get call stack backtrace for core */
    getBacktrace(core?: Core): Promise<Backtrace>;
    /** Get MSP/PSP stack pointers, low watermarks, and overflow count */
    getStackReport(core?: Core): Promise<StackReport>;
    /** List peripheral blocks (when block is empty) or inspect a block's registers */
    getPeriph(core?: Core, block?: string, json?: boolean): Promise<string>;
    /** List fitted off-chip parts (`MODEL@ENDPOINT` lines) */
    getListParts(core?: Core): Promise<string[]>;
    /** Sampled call stacks folded over [fromNs, toNs) */
    getFolded(core?: Core, thread?: number, fromNs?: bigint, toNs?: bigint): Promise<string>;
    /** List time-travel execution branches in the history DAG */
    getBranches(): Promise<BranchItem[]>;
    /** Switch active execution branch in the history DAG */
    switchBranch(branch: number): Promise<boolean>;
    /** Delete a non-live execution branch */
    deleteBranch(branch: number, confirm?: boolean): Promise<boolean>;
    /** Confirm a pending fork after historical state mutation */
    confirmFork(confirm?: boolean): Promise<boolean>;
    /** Cancel a pending fork */
    cancelFork(): Promise<boolean>;
    /** Check whether a mutation fork is pending confirmation */
    getForkStatus(): Promise<ForkStatus>;
    /** Seek to a virtual time, cycle, frame, or bookmark target */
    seek(target: string): Promise<boolean>;
    /** Reverse-continue backwards to previous breakpoint or start of history */
    reverseContinue(core?: Core): Promise<boolean>;
    /** Play recorded history forward or backward */
    play(dir?: Direction, speedMilli?: bigint): Promise<boolean>;
    /** Query frame, iteration, marker, RTOS, or ISR index in recorded history */
    navQuery(args: NavQueryArgs): Promise<NavQueryResult>;
    /** Set a named history marker on a symbol or hex address */
    setMarker(name: string, place: string): Promise<boolean>;
    /** Query rewind pipeline RAM/disk frame accounting */
    getFrameStatus(): Promise<FrameStatusResult>;
    /** Compute architectural register, memory page, and peripheral state diff between two points */
    getDiff(a: string, b: string): Promise<DecodedDiff>;
    /** Injected touch or button input to guest firmware */
    sendInput(args: ScheduleInputArgs): Promise<boolean>;
    /** Send bytes to virtual console UART */
    sendConsoleInput(core: Core, bytes: Uint8Array): Promise<boolean>;
    private sendRaw;
    private onData;
    private processFrame;
    private dispatchTopicEvent;
    private cleanupPending;
}
//# sourceMappingURL=client.d.ts.map