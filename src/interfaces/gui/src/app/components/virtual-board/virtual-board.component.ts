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
    <div class="pane-card">
      <div class="pane-header">
        <div class="pane-title-group">
          <span class="pane-title">Virtual Board &amp; Display</span>
          <span class="panel-chip">{{ panelName() }}</span>
        </div>
        <div class="board-badges">
          <span class="badge res-badge" *ngIf="hasPanel()">{{ displayWidth() }} × {{ displayHeight() }}</span>
          <span class="badge fps-badge" [class.active]="fps() > 0">{{ fps() }} fps</span>
        </div>
      </div>

      <!-- Authentic Renesas EK-RA8D2 Emerald FR4 PCB -->
      <div class="pcb-board">
        <!-- Corner Standoffs & Silkscreen -->
        <div class="pcb-top-silkscreen">
          <span class="standoff"></span>
          <span class="silk-text">RENESAS EK-RA8D2 • R7FA8D2BHECBD (M85 + M33)</span>
          <span class="standoff"></span>
        </div>

        <!-- Dynamic MIPI-DSI / GLCDC TFT Bezel (or Headless Notice) -->
        <div *ngIf="hasPanel()" class="tft-bezel">
          <div class="tft-silk">J14 MIPI-DSI • {{ panelName() }} • GT911 Capacitive Touch</div>
          <div
            class="lcd-viewport"
            [style.aspect-ratio]="displayWidth() + ' / ' + displayHeight()"
          >
            <canvas
              #lcdCanvas
              [width]="displayWidth()"
              [height]="displayHeight()"
              (pointerdown)="onPointerDown($event)"
              (pointerup)="onPointerUp($event)"
              (pointerleave)="onPointerCancel()"
              class="lcd-canvas"
            ></canvas>
            <div *ngIf="isWaitingForSignal()" class="lcd-standby">
              <div class="standby-ring"></div>
              <span class="standby-title">{{ isConnected() ? 'GLCDC Scanout Standby' : 'Display Offline' }}</span>
              <span class="standby-sub">
                {{ isConnected() ? 'Touch gestures active • Waiting for first dirty-rect frame' : 'Connect emulator backend to stream framebuffer' }}
              </span>
            </div>
          </div>
        </div>

        <div *ngIf="!hasPanel()" class="headless-notice">
          Headless board profile fitted (no GLCDC / E-ink panel attached). Front-panel GPIO LEDs and switches remain live.
        </div>

        <!-- Dynamic Front-Panel SMD LEDs & 3D Tactile Switches from BoardParts RPC -->
        <div class="front-panel">
          <div class="panel-group">
            <span class="silk-label">USER LEDS ({{ leds().length }})</span>
            <div class="leds-strip">
              <div
                *ngFor="let led of leds(); let i = index"
                class="smd-led-slot"
                [title]="led.name + (led.lit ? ' (ON)' : ' (OFF)')"
              >
                <div class="smd-package">
                  <div
                    class="smd-lens"
                    [class.lit]="led.lit"
                    [style.--led-color]="led.color"
                  ></div>
                </div>
                <span class="comp-silk">{{ led.shortName }}</span>
              </div>
            </div>
          </div>

          <div class="panel-group switches-group" *ngIf="switchNames().length > 0">
            <span class="silk-label">TACTILE SWITCHES</span>
            <div class="switches-strip">
              <button
                *ngFor="let sw of switchNames(); let idx = index"
                type="button"
                class="tactile-switch"
                (mousedown)="pressButton(idx)"
                [disabled]="!isConnected()"
                [title]="'Trigger hardware switch ' + sw + ' (channel ' + idx + ')'"
              >
                <span class="switch-cap"></span>
                <span class="comp-silk">{{ sw }}</span>
              </button>
            </div>
          </div>
        </div>

        <div class="pcb-bottom-silkscreen">
          <span class="standoff"></span>
          <span class="silk-coords" *ngIf="lastTouchText()">TOUCH {{ lastTouchText() }}</span>
          <span class="silk-coords" *ngIf="!lastTouchText()">PB01 / P008 / P600 GPIO MATRIX</span>
          <span class="standoff"></span>
        </div>
      </div>
    </div>
  `,
  styles: [`
    .pane-card {
      background: linear-gradient(180deg, rgba(15, 23, 42, 0.84), rgba(6, 10, 19, 0.92));
      border: 1px solid rgba(255, 255, 255, 0.08);
      box-shadow: inset 0 1px 0 0 rgba(255, 255, 255, 0.06), 0 8px 24px rgba(0, 0, 0, 0.35);
      border-radius: 10px;
      overflow: hidden;
      display: flex;
      flex-direction: column;
    }

    .pane-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 8px 12px;
      border-bottom: 1px solid rgba(255, 255, 255, 0.07);
      background: rgba(15, 23, 42, 0.55);
    }

    .pane-title-group {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .pane-title {
      font-size: 0.8rem;
      font-weight: 600;
      color: #f1f5f9;
    }

    .panel-chip {
      font-size: 0.66rem;
      font-family: "JetBrains Mono", monospace;
      color: #34d399;
      background: rgba(16, 185, 129, 0.12);
      border: 1px solid rgba(52, 211, 153, 0.25);
      padding: 1px 6px;
      border-radius: 4px;
    }

    .board-badges {
      display: flex;
      gap: 6px;
    }

    .badge {
      font-size: 0.68rem;
      padding: 2px 6px;
      border-radius: 4px;
      font-family: "JetBrains Mono", monospace;
      border: 1px solid rgba(255, 255, 255, 0.07);
    }

    .res-badge {
      background: rgba(15, 23, 42, 0.8);
      color: #94a3b8;
    }

    .fps-badge {
      background: rgba(15, 23, 42, 0.8);
      color: #64748b;
    }
    .fps-badge.active {
      background: rgba(34, 197, 94, 0.16);
      color: #4ade80;
      border-color: rgba(74, 222, 128, 0.35);
    }

    /* Authentic EK-RA8D2 Emerald FR4 PCB */
    .pcb-board {
      padding: 10px 12px;
      background:
        radial-gradient(circle at 20% 15%, rgba(42, 118, 72, 0.35), transparent 55%),
        repeating-linear-gradient(
          90deg,
          rgba(255, 255, 255, 0.015) 0px,
          rgba(255, 255, 255, 0.015) 1px,
          transparent 1px,
          transparent 14px
        ),
        linear-gradient(165deg, #1b4d2e 0%, #123720 65%, #0c2616 100%);
      border-top: 1px solid rgba(255, 255, 255, 0.08);
      box-shadow: inset 0 0 22px rgba(0, 0, 0, 0.65);
      display: flex;
      flex-direction: column;
      gap: 10px;
    }

    .pcb-top-silkscreen,
    .pcb-bottom-silkscreen {
      display: flex;
      align-items: center;
      justify-content: space-between;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.6rem;
      letter-spacing: 0.08em;
      color: rgba(241, 245, 249, 0.72);
    }

    .standoff {
      width: 10px;
      height: 10px;
      border-radius: 50%;
      background: #09150d;
      border: 2px solid #d4af37;
      box-shadow: inset 0 1px 2px rgba(0, 0, 0, 0.9);
    }

    .tft-bezel {
      background: linear-gradient(180deg, #181a1f 0%, #0d0f13 100%);
      padding: 7px 9px 9px;
      border-radius: 7px;
      border: 1px solid rgba(255, 255, 255, 0.14);
      box-shadow: 0 6px 18px rgba(0, 0, 0, 0.65), inset 0 1px 0 rgba(255, 255, 255, 0.08);
      display: flex;
      flex-direction: column;
      gap: 5px;
    }

    .tft-silk {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.58rem;
      color: #64748b;
      letter-spacing: 0.05em;
    }

    .lcd-viewport {
      position: relative;
      width: 100%;
      background: #030508;
      border: 1px solid #262932;
      border-radius: 3px;
      overflow: hidden;
      line-height: 0;
    }

    .lcd-canvas {
      display: block;
      width: 100%;
      height: 100%;
      cursor: crosshair;
      touch-action: none;
    }

    .lcd-standby {
      position: absolute;
      inset: 0;
      background: radial-gradient(circle at center, rgba(9, 14, 24, 0.82), rgba(3, 6, 12, 0.94));
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 5px;
      padding: 12px;
      text-align: center;
      pointer-events: none;
    }

    .standby-ring {
      width: 18px;
      height: 18px;
      border-radius: 50%;
      border: 2px solid rgba(56, 189, 248, 0.45);
      border-top-color: #38bdf8;
      animation: spin 2.4s linear infinite;
      margin-bottom: 2px;
    }

    @keyframes spin {
      to { transform: rotate(360deg); }
    }

    .standby-title {
      font-size: 0.76rem;
      font-weight: 600;
      color: #cbd5e1;
      line-height: 1.3;
    }

    .standby-sub {
      font-size: 0.66rem;
      color: #64748b;
      line-height: 1.3;
    }

    .headless-notice {
      padding: 16px;
      background: rgba(0, 0, 0, 0.4);
      border: 1px dashed rgba(255, 255, 255, 0.22);
      border-radius: 6px;
      font-size: 0.72rem;
      color: #cbd5e1;
      text-align: center;
    }

    .front-panel {
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-wrap: wrap;
      gap: 12px;
      background: rgba(6, 18, 11, 0.68);
      padding: 8px 11px;
      border-radius: 6px;
      border: 1px solid rgba(255, 255, 255, 0.12);
    }

    .panel-group {
      display: flex;
      flex-direction: column;
      gap: 6px;
    }

    .silk-label {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.58rem;
      font-weight: 700;
      letter-spacing: 0.08em;
      color: rgba(241, 245, 249, 0.7);
    }

    .leds-strip {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
    }

    .smd-led-slot {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 3px;
    }

    .smd-package {
      width: 20px;
      height: 20px;
      border-radius: 4px;
      background: #1f2428;
      border: 1px solid rgba(255, 255, 255, 0.18);
      display: flex;
      align-items: center;
      justify-content: center;
      box-shadow: inset 0 1px 2px rgba(0, 0, 0, 0.8);
    }

    .smd-lens {
      width: 11px;
      height: 11px;
      border-radius: 50%;
      background: radial-gradient(circle at 35% 35%, #475569, #1e293b);
      transition: all 0.12s ease;
    }

    .smd-lens.lit {
      background: radial-gradient(circle at 35% 35%, #ffffff 5%, var(--led-color, #22c55e) 60%);
      box-shadow:
        0 0 8px var(--led-color, #22c55e),
        0 0 18px var(--led-color, #22c55e);
    }

    .comp-silk {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.6rem;
      color: #e2e8f0;
      white-space: nowrap;
    }

    .switches-strip {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
    }

    .tactile-switch {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 3px;
      background: linear-gradient(180deg, #cbd5e1 0%, #94a3b8 100%);
      border: 1px solid #475569;
      border-radius: 5px;
      padding: 4px 10px 3px;
      cursor: pointer;
      box-shadow: 0 2px 0 #1e293b, 0 3px 6px rgba(0, 0, 0, 0.45);
      transition: transform 0.08s ease, box-shadow 0.08s ease;
    }
    .tactile-switch .comp-silk {
      color: #0f172a;
      font-weight: 700;
    }
    .tactile-switch:active:not(:disabled) {
      transform: translateY(2px);
      box-shadow: 0 0 0 #1e293b;
    }
    .tactile-switch:disabled {
      opacity: 0.4;
      cursor: not-allowed;
    }

    .switch-cap {
      width: 12px;
      height: 12px;
      border-radius: 50%;
      background: radial-gradient(circle at 35% 30%, #334155, #0f172a);
      border: 1px solid #020617;
    }

    .silk-coords {
      color: rgba(226, 232, 240, 0.65);
    }
  `]
})
export class VirtualBoardComponent implements AfterViewInit, OnDestroy {
  @ViewChild('lcdCanvas') canvasRef?: ElementRef<HTMLCanvasElement>;

  private emu = inject(EmulatorService);
  private sub: Subscription | null = null;
  private renderer: FramebufferRenderer | null = null;
  private pointerDownPos: { x: number; y: number } | null = null;

  // Dynamic EK-RA8D2 default (1024x600 ER-TFT070-6), updated automatically from BoardParts RPC
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
    const fallbackNames = ['LED1 BLUE', 'LED2 GREEN', 'LED3 RED'];
    const fallbackColors = ['#3b82f6', '#22c55e', '#ef4444', '#eab308', '#a855f7', '#06b6d4', '#f97316', '#ec4899'];

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
    // Dynamically resize framebuffer dimensions whenever boardParts changes (e.g., 1024x600 TFT vs 1072x1448 E-ink)
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
      this.lastTouchText.set(`TAP (${fromX}, ${fromY})`);
      void this.emu.sendTouch(InputKind.Tap, fromX, fromY);
    } else {
      this.lastTouchText.set(`SWIPE (${fromX},${fromY})→(${toX},${toY})`);
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
