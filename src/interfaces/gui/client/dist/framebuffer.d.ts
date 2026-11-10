/**
 * HTML5 Canvas LCD Framebuffer Rendering Helper
 *
 * Decodes topic 0x0103 (lcd_dirty) DirtyRect pixel buffers into RGBA
 * ImageData and renders directly to HTML5 Canvas.
 */
import { DirtyRect } from "./types.js";
export type PixelFormat = "grayscale" | "rgb565" | "rgb24" | "argb32" | "rgba32";
/**
 * Detect pixel format based on pixel buffer length and rectangle dimensions
 */
export declare function detectPixelFormat(rect: DirtyRect): PixelFormat;
/**
 * Convert DirtyRect pixel buffer to RGBA Uint8ClampedArray suitable for ImageData.
 * Works universally in browsers and headless/Node.js environments.
 */
export declare function dirtyRectToRgba(rect: DirtyRect, targetRgba?: Uint8ClampedArray, forcedFormat?: PixelFormat): Uint8ClampedArray;
/**
 * Create standard browser ImageData from DirtyRect
 */
export declare function createImageDataFromDirtyRect(rect: DirtyRect, forcedFormat?: PixelFormat): ImageData;
/**
 * Paint a DirtyRect onto a standard 2D canvas rendering context
 */
export declare function paintDirtyRect(ctx: CanvasRenderingContext2D, rect: DirtyRect, forcedFormat?: PixelFormat): void;
/**
 * FramebufferRenderer: High-level helper managing live LCD rendering on HTML5 canvas
 */
export declare class FramebufferRenderer {
    readonly canvas: HTMLCanvasElement;
    private readonly ctx;
    private frameCount;
    private lastFpsTimestamp;
    private fps;
    constructor(canvas: HTMLCanvasElement, options?: {
        defaultWidth?: number;
        defaultHeight?: number;
    });
    /** Render an incoming dirty rect to the canvas */
    render(rect: DirtyRect, forcedFormat?: PixelFormat): void;
    /** Clear canvas to solid background */
    clear(color?: string): void;
    /** Resize canvas */
    resize(width: number, height: number): void;
    /** Current frames-per-second metric */
    get currentFps(): number;
    /** Total rendered dirty rect frame count */
    get totalFrames(): number;
    private updateMetrics;
}
//# sourceMappingURL=framebuffer.d.ts.map