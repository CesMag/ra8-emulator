/**
 * RA8 Emulator Typed WebSocket RPC Client
 *
 * Implements RA8RpcClient for seamless browser and Node.js communication with
 * ra8-emulator RFC 6455 transport bridge. Zero runtime dependencies.
 */
import { Method, Topic, Core, Register, RunMode, Hello, MetricsReport, DirtyRect, Stopped, UartEvent, SessionEvent, TransportEvent, RpcEventEnvelope, BoardParts, Backtrace, ScheduleInputArgs } from "./types.js";
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
    /** Set instruction breakpoint */
    setBreakpoint(core: Core, address: number): Promise<boolean>;
    /** Clear instruction breakpoint */
    clearBreakpoint(core: Core, address: number): Promise<boolean>;
    /** Advance simulation by virtual nanoseconds */
    advance(core: Core, ns: bigint): Promise<boolean>;
    /** Set emulation pacing speed (0 = unthrottled) */
    setSpeed(core?: Core, milli?: bigint | number): Promise<boolean>;
    /** Get served board front-panel profile, LEDs, and switches */
    getBoardParts(): Promise<BoardParts>;
    /** Get call stack backtrace for core */
    getBacktrace(core?: Core): Promise<Backtrace>;
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