import {
  Component,
  ElementRef,
  ViewChild,
  OnInit,
  OnDestroy,
  AfterViewInit,
  inject,
  signal,
  computed
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { Subscription } from 'rxjs';
import { EmulatorService } from '../../services/emulator.service';
import { FramebufferRenderer, InputKind, DirtyRect } from 'ra8-rpc-client';

@Component({
  selector: 'app-virtual-board',
  standalone: true,
  imports: [CommonModule],
  template: `
    <div class="virtual-board-card">
      <div class="board-header">
        <div class="board-title">
          <span class="icon">🖥️</span>
          <span class="title-text">Virtual Board & LCD Display</span>
        </div>
        <div class="board-badges">
          <span class="badge res-badge">{{ displayWidth }} × {{ displayHeight }}</span>
          <span class="badge fps-badge" [class.active]="fps() > 0">{{ fps() }} FPS</span>
        </div>
      </div>

      <!-- The Board PCB Bezel -->
      <div class="pcb-bezel">
        <div class="lcd-housing">
          <canvas
            #lcdCanvas
            [width]="displayWidth"
            [height]="displayHeight"
            (pointerdown)="onPointerDown($event)"
            (pointerup)="onPointerUp($event)"
            (pointerleave)="onPointerCancel()"
            class="lcd-canvas"
          ></canvas>
          <div *ngIf="isWaitingForSignal()" class="lcd-overlay">
            <span class="pulse-icon">⚡</span>
            <span>Awaiting Display Signal</span>
          </div>
        </div>

        <!-- Front-Panel Controls & Indicators -->
        <div class="front-panel">
          <!-- LED Indicators -->
          <div class="panel-section leds-section">
            <span class="section-label">USER LEDS</span>
            <div class="leds-container">
              <div
                *ngFor="let led of leds(); let i = index"
                class="led-item"
                [title]="'LED ' + (i + 1)"
              >
                <div
                  class="led-indicator"
                  [class.lit]="led.lit"
                  [style.--led-color]="led.color"
                ></div>
                <span class="led-label">{{ led.name }}</span>
              </div>
            </div>
          </div>

          <!-- Tactile Push Buttons -->
          <div class="panel-section buttons-section">
            <span class="section-label">BUTTONS</span>
            <div class="buttons-container">
              <button
                type="button"
                class="tactile-btn"
                (mousedown)="pressButton(0)"
                [disabled]="!isConnected()"
              >
                SW1
              </button>
              <button
                type="button"
                class="tactile-btn"
                (mousedown)="pressButton(1)"
                [disabled]="!isConnected()"
              >
                SW2
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  `,
  styles: [`
    .virtual-board-card {
      background: var(--bg-secondary);
      border: 1px solid var(--border-color);
      border-radius: 8px;
      overflow: hidden;
      display: flex;
      flex-direction: column;
    }

    .board-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 8px 12px;
      background: var(--bg-tertiary);
      border-bottom: 1px solid var(--border-color);
    }

    .board-title {
      display: flex;
      align-items: center;
      gap: 6px;
      font-weight: 600;
      font-size: 0.85rem;
      color: var(--text-primary);
    }

    .board-badges {
      display: flex;
      gap: 6px;
    }

    .badge {
      font-size: 0.7rem;
      padding: 2px 6px;
      border-radius: 4px;
      font-family: monospace;
    }

    .res-badge {
      background: #28303d;
      color: #9da5b4;
    }

    .fps-badge {
      background: #2a2d33;
      color: #6c7380;
    }

    .fps-badge.active {
      background: rgba(76, 175, 80, 0.2);
      color: #4caf50;
      font-weight: bold;
    }

    /* PCB Frame */
    .pcb-bezel {
      padding: 12px;
      background: #113824; /* EK-RA8 PCB Green */
      background: radial-gradient(circle at 50% 50%, #17482f 0%, #0d2c1c 100%);
      box-shadow: inset 0 0 10px rgba(0,0,0,0.6);
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 12px;
    }

    .lcd-housing {
      position: relative;
      background: #000;
      border: 3px solid #222;
      border-radius: 4px;
      box-shadow: 0 4px 12px rgba(0,0,0,0.5);
      line-height: 0;
      max-width: 100%;
      overflow: hidden;
    }

    .lcd-canvas {
      display: block;
      cursor: crosshair;
      touch-action: none;
      max-width: 100%;
      height: auto;
    }

    .lcd-overlay {
      position: absolute;
      inset: 0;
      background: rgba(10, 15, 20, 0.85);
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      color: var(--text-secondary);
      font-size: 0.85rem;
      gap: 6px;
    }

    .pulse-icon {
      font-size: 1.5rem;
      animation: pulse 1.5s infinite;
    }

    @keyframes pulse {
      0%, 100% { opacity: 0.3; transform: scale(0.9); }
      50% { opacity: 1; transform: scale(1.1); }
    }

    /* Front Panel Controls */
    .front-panel {
      display: flex;
      justify-content: space-between;
      width: 100%;
      max-width: 480px;
      background: rgba(0, 0, 0, 0.4);
      padding: 8px 12px;
      border-radius: 6px;
      border: 1px solid rgba(255, 255, 255, 0.08);
    }

    .panel-section {
      display: flex;
      flex-direction: column;
      gap: 4px;
    }

    .section-label {
      font-size: 0.65rem;
      letter-spacing: 0.05em;
      color: rgba(255, 255, 255, 0.5);
      font-weight: 700;
    }

    .leds-container {
      display: flex;
      gap: 12px;
    }

    .led-item {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 2px;
    }

    .led-indicator {
      width: 14px;
      height: 14px;
      border-radius: 3px;
      background: #2b3036;
      border: 1px solid #1a1e22;
      transition: all 0.15s ease;
    }

    .led-indicator.lit {
      background: var(--led-color, #4caf50);
      box-shadow: 0 0 8px var(--led-color, #4caf50), inset 0 0 4px #fff;
    }

    .led-label {
      font-size: 0.65rem;
      font-family: monospace;
      color: #cbd5e1;
    }

    .buttons-container {
      display: flex;
      gap: 8px;
    }

    .tactile-btn {
      background: #2d3748;
      color: #edf2f7;
      border: 1px solid #4a5568;
      border-radius: 4px;
      padding: 4px 10px;
      font-size: 0.75rem;
      font-weight: 600;
      cursor: pointer;
      box-shadow: 0 2px 0 #1a202c;
      transition: all 0.1s ease;
    }

    .tactile-btn:active {
      transform: translateY(2px);
      box-shadow: none;
    }

    .tactile-btn:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
  `]
})
export class VirtualBoardComponent implements OnInit, AfterViewInit, OnDestroy {
  @ViewChild('lcdCanvas') canvasRef!: ElementRef<HTMLCanvasElement>;

  private emu = inject(EmulatorService);
  private sub: Subscription | null = null;
  private renderer: FramebufferRenderer | null = null;

  public displayWidth = 480;
  public displayHeight = 272;
  public fps = signal<number>(0);
  public frameCount = signal<number>(0);
  private pointerDownPos: { x: number; y: number } | null = null;

  public isConnected = computed(() => this.emu.connectionState() === 'connected');
  public isWaitingForSignal = computed(() => !this.isConnected() || this.frameCount() === 0);

  public leds = computed(() => {
    const states = this.emu.ledStates();
    const parts = this.emu.boardParts();
    const names = parts?.ledNames?.length ? parts.ledNames : ['LED1 (G)', 'LED2 (R)', 'LED3 (B)'];
    const colors = ['#22c55e', '#ef4444', '#3b82f6', '#eab308'];

    return names.slice(0, 4).map((name, i) => ({
      name,
      lit: states[i] ?? false,
      color: colors[i % colors.length]
    }));
  });

  ngOnInit(): void {}

  ngAfterViewInit(): void {
    const canvas = this.canvasRef.nativeElement;
    this.renderer = new FramebufferRenderer(canvas, {
      defaultWidth: this.displayWidth,
      defaultHeight: this.displayHeight
    });

    this.sub = this.emu.lcdDirty$.subscribe((rect: DirtyRect) => {
      if (this.renderer) {
        if (rect.width > 0 && rect.height > 0) {
          if (rect.width !== this.displayWidth || rect.height !== this.displayHeight) {
            this.displayWidth = rect.width;
            this.displayHeight = rect.height;
            this.renderer.resize(rect.width, rect.height);
          }
          this.renderer.render(rect);
          this.frameCount.update(n => n + 1);
          this.fps.set(this.renderer.currentFps);
        }
      }
    });
  }

  ngOnDestroy(): void {
    if (this.sub) {
      this.sub.unsubscribe();
      this.sub = null;
    }
  }

  public onPointerDown(event: PointerEvent): void {
    const canvas = this.canvasRef.nativeElement;
    const rect = canvas.getBoundingClientRect();
    const scaleX = this.displayWidth / rect.width;
    const scaleY = this.displayHeight / rect.height;
    const x = Math.round((event.clientX - rect.left) * scaleX);
    const y = Math.round((event.clientY - rect.top) * scaleY);

    this.pointerDownPos = { x, y };
  }

  public onPointerUp(event: PointerEvent): void {
    if (!this.pointerDownPos) return;

    const canvas = this.canvasRef.nativeElement;
    const rect = canvas.getBoundingClientRect();
    const scaleX = this.displayWidth / rect.width;
    const scaleY = this.displayHeight / rect.height;
    const toX = Math.round((event.clientX - rect.left) * scaleX);
    const toY = Math.round((event.clientY - rect.top) * scaleY);
    const fromX = this.pointerDownPos.x;
    const fromY = this.pointerDownPos.y;
    this.pointerDownPos = null;

    const dist = Math.hypot(toX - fromX, toY - fromY);
    if (dist < 8) {
      // Tap gesture
      void this.emu.sendTouch(InputKind.Tap, fromX, fromY);
    } else {
      // Swipe gesture
      void this.emu.sendTouch(InputKind.Swipe, fromX, fromY, toX, toY, 200_000_000n); // 200ms
    }
  }

  public onPointerCancel(): void {
    this.pointerDownPos = null;
  }

  public pressButton(btnIndex: number): void {
    void this.emu.sendButton(btnIndex);
  }
}
