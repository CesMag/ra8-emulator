import {
  Component,
  ElementRef,
  ViewChild,
  OnDestroy,
  AfterViewInit,
  inject,
  signal,
  computed,
  effect,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { Subscription } from 'rxjs';
import { EmulatorService, rgb565ToCssHex } from '../../services/emulator.service';
import { FramebufferRenderer, InputKind, DirtyRect } from 'ra8-rpc-client';

@Component({
  selector: 'app-virtual-board',
  standalone: true,
  imports: [CommonModule],
  template: `
    <div class="simulator-wrapper">
      <!-- Section Header -->
      <div class="simulator-header">
        <div class="header-left">
          <span class="device-title">Virtual Hardware Bench</span>
          <span class="panel-tag">{{ panelName() }}</span>
        </div>
        <div class="header-right">
          <span class="meta-pill font-mono" *ngIf="hasPanel()">{{ displayWidth() }} × {{ displayHeight() }}</span>
          <span class="meta-pill font-mono" [class.live]="fps() > 0">{{ fps() }} fps</span>
        </div>
      </div>

      <!-- Apple Simulator Device Frame -->
      <div class="simulator-stage">
        <div *ngIf="hasPanel()" class="device-bezel">
          <div
            class="screen-viewport"
            [style.aspect-ratio]="displayWidth() + ' / ' + displayHeight()"
          >
            <canvas
              #lcdCanvas
              [width]="displayWidth()"
              [height]="displayHeight()"
              (pointerdown)="onPointerDown($event)"
              (pointerup)="onPointerUp($event)"
              (pointerleave)="onPointerCancel()"
              class="screen-canvas"
            ></canvas>
            <div *ngIf="isWaitingForSignal()" class="screen-standby">
              <div class="standby-spinner"></div>
              <span class="standby-text">{{ isConnected() ? 'Awaiting GLCDC scanout…' : 'Simulator Offline' }}</span>
              <span class="standby-hint">
                {{ isConnected() ? 'Touch gestures enabled' : 'Connect backend to stream display' }}
              </span>
            </div>
          </div>
        </div>

        <div *ngIf="!hasPanel()" class="headless-device-card">
          <div class="headless-icon">📺</div>
          <div class="headless-title">Headless Board Profile</div>
          <div class="headless-desc">No display attached. Front-panel LEDs and tactile switches remain live.</div>
        </div>

        <!-- Docked Hardware Controls -->
        <div class="hardware-dock">
          <!-- User LEDs Strip -->
          <div class="dock-section">
            <span class="dock-label">LEDs</span>
            <div class="led-array">
              <div
                *ngFor="let led of leds(); let i = index"
                class="led-item"
                [title]="led.name + (led.lit ? ' (ON)' : ' (OFF)')"
              >
                <div
                  class="micro-led"
                  [class.lit]="led.lit"
                  [style.--led-color]="led.color"
                ></div>
                <span class="led-name">{{ led.shortName }}</span>
              </div>
            </div>
          </div>

          <div class="dock-divider"></div>

          <!-- Tactile Push Buttons -->
          <div class="dock-section" *ngIf="switchNames().length > 0">
            <span class="dock-label">Buttons</span>
            <div class="button-array">
              <button
                *ngFor="let sw of switchNames(); let idx = index"
                type="button"
                class="tactile-btn"
                (mousedown)="pressButton(idx)"
                [disabled]="!isConnected()"
                [title]="'Press ' + sw"
              >
                {{ sw }}
              </button>
            </div>
          </div>

          <!-- Touch / GPIO Telemetry -->
          <div class="dock-section meta-section" *ngIf="lastTouchText()">
            <span class="dock-label">Touch</span>
            <span class="touch-text font-mono">{{ lastTouchText() }}</span>
          </div>
        </div>
      </div>
    </div>
  `,
  styles: [`
    .simulator-wrapper {
      display: flex;
      flex-direction: column;
      height: 100%;
      background: var(--bg-app);
      user-select: none;
    }

    .simulator-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 8px 12px;
      border-bottom: 1px solid var(--border-subtle);
      background: var(--bg-surface);
    }

    .header-left, .header-right {
      display: flex;
      align-items: center;
      gap: 6px;
    }

    .device-title {
      font-size: 11px;
      font-weight: 600;
      color: var(--text-primary);
    }

    .panel-tag {
      font-size: 10px;
      color: var(--text-secondary);
      background: var(--border-subtle);
      padding: 1px 6px;
      border-radius: var(--radius-sm);
      font-family: var(--font-mono);
    }

    .meta-pill {
      font-size: 10px;
      padding: 1px 6px;
      border-radius: var(--radius-sm);
      background: var(--border-subtle);
      color: var(--text-secondary);
    }
    .meta-pill.live {
      background: var(--accent-green-subtle);
      color: var(--accent-green);
    }

    .simulator-stage {
      padding: 14px;
      display: flex;
      flex-direction: column;
      gap: 12px;
      overflow-y: auto;
      flex: 1;
    }

    /* Apple Simulator Device Frame */
    .device-bezel {
      background: var(--bg-surface-elevated);
      border: 1px solid var(--border-strong);
      border-radius: 14px;
      padding: 8px;
      box-shadow: 0 4px 16px rgba(0, 0, 0, 0.2);
    }

    .screen-viewport {
      position: relative;
      width: 100%;
      max-height: 480px;
      background: #000000;
      border-radius: 8px;
      overflow: hidden;
      display: flex;
      align-items: center;
      justify-content: center;
    }

    .screen-canvas {
      width: 100%;
      height: 100%;
      display: block;
      image-rendering: pixelated;
      cursor: crosshair;
    }

    .screen-standby {
      position: absolute;
      inset: 0;
      background: rgba(18, 18, 20, 0.88);
      backdrop-filter: blur(4px);
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 6px;
      padding: 16px;
      text-align: center;
    }

    .standby-spinner {
      width: 20px;
      height: 20px;
      border-radius: 50%;
      border: 2px solid rgba(255, 255, 255, 0.16);
      border-top-color: var(--accent-blue);
      animation: spin 0.8s linear infinite;
    }

    @keyframes spin {
      to { transform: rotate(360deg); }
    }

    .standby-text {
      font-size: 12px;
      font-weight: 500;
      color: #f5f5f7;
    }

    .standby-hint {
      font-size: 10px;
      color: #98989d;
    }

    .headless-device-card {
      background: var(--bg-surface);
      border: 1px dashed var(--border-strong);
      border-radius: 12px;
      padding: 24px 16px;
      display: flex;
      flex-direction: column;
      align-items: center;
      text-align: center;
      gap: 6px;
    }
    .headless-icon {
      font-size: 24px;
    }
    .headless-title {
      font-size: 13px;
      font-weight: 600;
      color: var(--text-primary);
    }
    .headless-desc {
      font-size: 11px;
      color: var(--text-secondary);
      max-width: 260px;
    }

    /* Docked Hardware Controls */
    .hardware-dock {
      background: var(--bg-surface);
      border: 1px solid var(--border-subtle);
      border-radius: 10px;
      padding: 8px 12px;
      display: flex;
      align-items: center;
      gap: 12px;
      flex-wrap: wrap;
    }

    .dock-section {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .dock-label {
      font-size: 10px;
      font-weight: 600;
      color: var(--text-tertiary);
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }

    .dock-divider {
      width: 1px;
      height: 18px;
      background: var(--border-subtle);
    }

    .led-array {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .led-item {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 2px;
    }

    .micro-led {
      width: 9px;
      height: 9px;
      border-radius: 50%;
      background: var(--bg-well);
      border: 1px solid var(--border-strong);
      transition: background 0.12s, box-shadow 0.12s;
    }

    .micro-led.lit {
      background: var(--led-color, var(--accent-green));
      box-shadow: 0 0 8px var(--led-color, var(--accent-green));
    }

    .led-name {
      font-size: 9px;
      font-family: var(--font-mono);
      color: var(--text-secondary);
    }

    .button-array {
      display: flex;
      gap: 6px;
    }

    .tactile-btn {
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      color: var(--text-primary);
      padding: 3px 8px;
      font-size: 11px;
      font-weight: 500;
      cursor: pointer;
      box-shadow: 0 1px 2px rgba(0, 0, 0, 0.12);
      transition: transform 0.06s ease, background 0.12s;
    }

    .tactile-btn:active:not(:disabled) {
      transform: translateY(1px);
      background: var(--bg-surface-elevated);
    }

    .tactile-btn:disabled {
      opacity: 0.35;
      cursor: not-allowed;
    }

    .meta-section {
      margin-left: auto;
    }

    .touch-text {
      font-size: 10px;
      color: var(--accent-blue);
    }
  `]
})
export class VirtualBoardComponent implements AfterViewInit, OnDestroy {
  @ViewChild('lcdCanvas') canvasRef?: ElementRef<HTMLCanvasElement>;

  private emu = inject(EmulatorService);
  private sub: Subscription | null = null;
  private renderer: FramebufferRenderer | null = null;
  private pointerDownPos: { x: number; y: number } | null = null;

  public displayWidth = signal<number>(1024);
  public displayHeight = signal<number>(600);
  public fps = signal<number>(0);
  public frameCount = signal<number>(0);
  public lastTouchText = signal<string>('');

  public isConnected = computed(() => this.emu.connectionState() === 'connected');
  public isWaitingForSignal = computed(() => !this.isConnected() || this.frameCount() === 0);

  public hasPanel = computed(() => {
    const parts = this.emu.boardParts();
    if (!parts) return true;
    return parts.panel !== '' && parts.panelWidth > 0 && parts.panelHeight > 0;
  });

  public panelName = computed(() => {
    const parts = this.emu.boardParts();
    if (!parts) return 'ER-TFT070-6';
    return parts.panel || 'Headless';
  });

  public switchNames = computed<string[]>(() => {
    const parts = this.emu.boardParts();
    return parts ? parts.switchNames : ['SW1', 'SW2'];
  });

  public leds = computed(() => {
    const states = this.emu.ledStates();
    const parts = this.emu.boardParts();
    const fallbackNames = ['LED1 Blue', 'LED2 Green', 'LED3 Red'];
    const fallbackColors = ['#0a84ff', '#30d158', '#ff453a', '#ffd60a', '#bf5af2', '#64d2ff', '#ff9f0a', '#ff375f'];

    const names = parts && parts.ledNames.length > 0 ? parts.ledNames : fallbackNames;
    return names.slice(0, 8).map((name, i) => {
      const raw565 = parts?.ledColors?.[i];
      const color = raw565 !== undefined ? rgb565ToCssHex(raw565) : fallbackColors[i % fallbackColors.length]!;
      return {
        name,
        shortName: name.replace(/\s+/g, ' '),
        lit: states[i] ?? false,
        color,
      };
    });
  });

  constructor() {
    effect(() => {
      const parts = this.emu.boardParts();
      if (parts && parts.panelWidth > 0 && parts.panelHeight > 0) {
        this.displayWidth.set(parts.panelWidth);
        this.displayHeight.set(parts.panelHeight);
        if (this.renderer) {
          this.renderer.resize(parts.panelWidth, parts.panelHeight);
        }
      }
    });
  }

  ngAfterViewInit(): void {
    const canvas = this.canvasRef?.nativeElement;
    if (canvas) {
      this.renderer = new FramebufferRenderer(canvas, {
        defaultWidth: this.displayWidth(),
        defaultHeight: this.displayHeight(),
      });
    }

    this.sub = this.emu.lcdDirty$.subscribe((rect: DirtyRect) => {
      if (!this.renderer && this.canvasRef?.nativeElement) {
        this.renderer = new FramebufferRenderer(this.canvasRef.nativeElement, {
          defaultWidth: this.displayWidth(),
          defaultHeight: this.displayHeight(),
        });
      }
      if (this.renderer && rect.width > 0 && rect.height > 0) {
        const neededW = Math.max(this.displayWidth(), rect.x + rect.width);
        const neededH = Math.max(this.displayHeight(), rect.y + rect.height);
        if (neededW !== this.displayWidth() || neededH !== this.displayHeight()) {
          this.displayWidth.set(neededW);
          this.displayHeight.set(neededH);
          this.renderer.resize(neededW, neededH);
        }
        this.renderer.render(rect);
        this.frameCount.update((n) => n + 1);
        this.fps.set(this.renderer.currentFps);
      }
    });
  }

  ngOnDestroy(): void {
    this.sub?.unsubscribe();
    this.sub = null;
  }

  public onPointerDown(event: PointerEvent): void {
    const canvas = this.canvasRef?.nativeElement;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const scaleX = this.displayWidth() / Math.max(1, rect.width);
    const scaleY = this.displayHeight() / Math.max(1, rect.height);
    const x = Math.max(0, Math.min(this.displayWidth() - 1, Math.round((event.clientX - rect.left) * scaleX)));
    const y = Math.max(0, Math.min(this.displayHeight() - 1, Math.round((event.clientY - rect.top) * scaleY)));
    this.pointerDownPos = { x, y };
  }

  public onPointerUp(event: PointerEvent): void {
    if (!this.pointerDownPos) return;
    const canvas = this.canvasRef?.nativeElement;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const scaleX = this.displayWidth() / Math.max(1, rect.width);
    const scaleY = this.displayHeight() / Math.max(1, rect.height);
    const toX = Math.max(0, Math.min(this.displayWidth() - 1, Math.round((event.clientX - rect.left) * scaleX)));
    const toY = Math.max(0, Math.min(this.displayHeight() - 1, Math.round((event.clientY - rect.top) * scaleY)));
    const { x: fromX, y: fromY } = this.pointerDownPos;
    this.pointerDownPos = null;

    const dist = Math.hypot(toX - fromX, toY - fromY);
    if (dist < 8) {
      this.lastTouchText.set(`Tap (${fromX}, ${fromY})`);
      void this.emu.sendTouch(InputKind.Tap, fromX, fromY);
    } else {
      this.lastTouchText.set(`Swipe (${fromX},${fromY})→(${toX},${toY})`);
      void this.emu.sendTouch(InputKind.Swipe, fromX, fromY, toX, toY, 200_000_000n);
    }
  }

  public onPointerCancel(): void {
    this.pointerDownPos = null;
  }

  public pressButton(btnIndex: number): void {
    void this.emu.sendButton(btnIndex);
  }
}
