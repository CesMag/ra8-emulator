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
export function detectPixelFormat(rect: DirtyRect): PixelFormat {
  const pixelCount = rect.width * rect.height;
  if (pixelCount === 0) return "grayscale";

  const bytes = rect.pixels.length;
  if (bytes === pixelCount) {
    return "grayscale";
  } else if (bytes === pixelCount * 2) {
    return "rgb565";
  } else if (bytes === pixelCount * 3) {
    return "rgb24";
  } else if (bytes === pixelCount * 4) {
    return "rgba32";
  }
  return "grayscale";
}

/**
 * Convert DirtyRect pixel buffer to RGBA Uint8ClampedArray suitable for ImageData.
 * Works universally in browsers and headless/Node.js environments.
 */
export function dirtyRectToRgba(
  rect: DirtyRect,
  targetRgba?: Uint8ClampedArray,
  forcedFormat?: PixelFormat
): Uint8ClampedArray {
  const width = rect.width;
  const height = rect.height;
  const pixelCount = width * height;
  const out = targetRgba ?? new Uint8ClampedArray(pixelCount * 4);
  const src = rect.pixels;
  const format = forcedFormat ?? detectPixelFormat(rect);

  switch (format) {
    case "grayscale": {
      // 1 byte per pixel: R = G = B = gray, A = 255
      for (let i = 0; i < pixelCount; i++) {
        const g = src[i] ?? 0;
        const outIdx = i * 4;
        out[outIdx] = g;
        out[outIdx + 1] = g;
        out[outIdx + 2] = g;
        out[outIdx + 3] = 255;
      }
      break;
    }

    case "rgb565": {
      // 2 bytes per pixel little-endian: RRRRRGGG GGGBBBBB
      for (let i = 0; i < pixelCount; i++) {
        const lo = src[i * 2] ?? 0;
        const hi = src[i * 2 + 1] ?? 0;
        const val = lo | (hi << 8);

        const r = (val >> 11) & 0x1f;
        const g = (val >> 5) & 0x3f;
        const b = val & 0x1f;

        const outIdx = i * 4;
        out[outIdx] = (r * 255) / 31;
        out[outIdx + 1] = (g * 255) / 63;
        out[outIdx + 2] = (b * 255) / 31;
        out[outIdx + 3] = 255;
      }
      break;
    }

    case "rgb24": {
      // 3 bytes per pixel: R, G, B
      for (let i = 0; i < pixelCount; i++) {
        const srcIdx = i * 3;
        const outIdx = i * 4;
        out[outIdx] = src[srcIdx] ?? 0;
        out[outIdx + 1] = src[srcIdx + 1] ?? 0;
        out[outIdx + 2] = src[srcIdx + 2] ?? 0;
        out[outIdx + 3] = 255;
      }
      break;
    }

    case "argb32": {
      // 4 bytes per pixel: A, R, G, B
      for (let i = 0; i < pixelCount; i++) {
        const srcIdx = i * 4;
        const outIdx = i * 4;
        const a = src[srcIdx] ?? 0;
        const r = src[srcIdx + 1] ?? 0;
        const g = src[srcIdx + 2] ?? 0;
        const b = src[srcIdx + 3] ?? 0;
        out[outIdx] = r;
        out[outIdx + 1] = g;
        out[outIdx + 2] = b;
        out[outIdx + 3] = a;
      }
      break;
    }

    case "rgba32": {
      // 4 bytes per pixel: R, G, B, A
      for (let i = 0; i < pixelCount; i++) {
        const srcIdx = i * 4;
        const outIdx = i * 4;
        out[outIdx] = src[srcIdx] ?? 0;
        out[outIdx + 1] = src[srcIdx + 1] ?? 0;
        out[outIdx + 2] = src[srcIdx + 2] ?? 0;
        out[outIdx + 3] = src[srcIdx + 3] ?? 255;
      }
      break;
    }
  }

  return out;
}

/**
 * Create standard browser ImageData from DirtyRect
 */
export function createImageDataFromDirtyRect(
  rect: DirtyRect,
  forcedFormat?: PixelFormat
): ImageData {
  if (typeof ImageData === "undefined") {
    throw new Error("ImageData is only supported in browser or canvas environments");
  }
  const rgba = dirtyRectToRgba(rect, undefined, forcedFormat);
  return new ImageData(rgba as any, rect.width, rect.height);
}

/**
 * Paint a DirtyRect onto a standard 2D canvas rendering context
 */
export function paintDirtyRect(
  ctx: CanvasRenderingContext2D,
  rect: DirtyRect,
  forcedFormat?: PixelFormat
): void {
  if (rect.width === 0 || rect.height === 0) return;
  const imgData = createImageDataFromDirtyRect(rect, forcedFormat);
  ctx.putImageData(imgData, rect.x, rect.y);
}

/**
 * FramebufferRenderer: High-level helper managing live LCD rendering on HTML5 canvas
 */
export class FramebufferRenderer {
  private readonly ctx: CanvasRenderingContext2D;
  private frameCount = 0;
  private lastFpsTimestamp = 0;
  private fps = 0;

  constructor(
    public readonly canvas: HTMLCanvasElement,
    options: { defaultWidth?: number; defaultHeight?: number } = {}
  ) {
    const context = canvas.getContext("2d");
    if (!context) {
      throw new Error("Failed to get 2D rendering context for canvas");
    }
    this.ctx = context;
    if (options.defaultWidth && options.defaultHeight) {
      this.resize(options.defaultWidth, options.defaultHeight);
    }
  }

  /** Render an incoming dirty rect to the canvas */
  public render(rect: DirtyRect, forcedFormat?: PixelFormat): void {
    if (rect.width === 0 || rect.height === 0) return;

    // Auto-expand canvas if dirty rect extends beyond current canvas dimensions
    const requiredWidth = rect.x + rect.width;
    const requiredHeight = rect.y + rect.height;
    if (this.canvas.width < requiredWidth || this.canvas.height < requiredHeight) {
      this.resize(
        Math.max(this.canvas.width, requiredWidth),
        Math.max(this.canvas.height, requiredHeight)
      );
    }

    paintDirtyRect(this.ctx, rect, forcedFormat);
    this.updateMetrics();
  }

  /** Clear canvas to solid background */
  public clear(color = "#000000"): void {
    this.ctx.fillStyle = color;
    this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
  }

  /** Resize canvas */
  public resize(width: number, height: number): void {
    this.canvas.width = width;
    this.canvas.height = height;
    this.clear();
  }

  /** Current frames-per-second metric */
  public get currentFps(): number {
    return this.fps;
  }

  /** Total rendered dirty rect frame count */
  public get totalFrames(): number {
    return this.frameCount;
  }

  private updateMetrics(): void {
    this.frameCount++;
    const now = typeof performance !== "undefined" ? performance.now() : Date.now();
    if (this.lastFpsTimestamp === 0) {
      this.lastFpsTimestamp = now;
      return;
    }
    const elapsed = now - this.lastFpsTimestamp;
    if (elapsed >= 1000) {
      this.fps = Math.round((this.frameCount * 1000) / elapsed);
      this.frameCount = 0;
      this.lastFpsTimestamp = now;
    }
  }
}
