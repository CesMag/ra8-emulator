import { Component, inject, computed, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { EmulatorService } from '../../services/emulator.service';
import { Core } from 'ra8-rpc-client';

@Component({
  selector: 'app-connection-bar',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <header class="xcode-toolbar">
      <!-- Left: App Identity, Target Device, & Connection Status -->
      <div class="toolbar-section toolbar-left">
        <div class="app-identity">
          <div class="app-icon">RA8</div>
          <div class="app-titles">
            <span class="app-name">RA8 Workbench</span>
            <span class="target-chip">EK-RA8D2</span>
          </div>
        </div>

        <div class="conn-anchor">
          <button
            type="button"
            class="conn-pill-btn"
            [class.connected]="isConnected()"
            [class.connecting]="isConnecting()"
            (click)="showSettings.set(!showSettings())"
            title="Configure Emulator WebSocket Connection"
          >
            <span class="status-dot" [class.online]="isConnected()" [class.busy]="isConnecting()"></span>
            <span class="conn-text">{{ isConnected() ? 'Online' : isConnecting() ? 'Connecting…' : 'Offline' }}</span>
          </button>

          <!-- Settings Popover -->
          <div *ngIf="showSettings()" class="settings-popover">
            <div class="popover-header">
              <span>Emulator WebSocket</span>
              <button type="button" class="close-btn" (click)="showSettings.set(false)">✕</button>
            </div>
            <div class="popover-body">
              <label class="input-label" for="ws-url-input">Server Endpoint</label>
              <div class="input-row">
                <input
                  id="ws-url-input"
                  type="text"
                  class="xcode-input"
                  [ngModel]="urlInput()"
                  (ngModelChange)="urlInput.set($event)"
                  placeholder="ws://127.0.0.1:4567"
                  (keydown.enter)="applyConnection()"
                />
                <button
                  type="button"
                  class="xcode-btn"
                  [class.destructive]="isConnected()"
                  (click)="applyConnection()"
                >
                  {{ isConnected() ? 'Disconnect' : 'Connect' }}
                </button>
              </div>
              <div *ngIf="!isConnected()" class="cmd-help">
                <div class="cmd-label">Start local backend:</div>
                <code class="cmd-code" (click)="copyLaunchCommand()">{{ launchCommand() }}</code>
                <span class="copy-hint">{{ copied() ? 'Copied to clipboard' : 'Click code to copy' }}</span>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Center: Iconic Xcode Activity HUD -->
      <div class="toolbar-section toolbar-center">
        <div class="activity-hud" [class.offline]="!isConnected()" [class.running]="isRunning()">
          <ng-container *ngIf="isConnected()">
            <div class="hud-item core-m85">
              <span class="hud-core-label">M85</span>
              <span class="hud-value font-mono">0x{{ toHex8(emu.cpu0Pc()) }}</span>
              <span class="hud-sub">{{ emu.cpu0StateLabel() }}</span>
            </div>

            <span class="hud-divider"></span>

            <div class="hud-item core-m33" [class.dimmed]="!cpu1Attached()">
              <span class="hud-core-label">M33</span>
              <span class="hud-value font-mono" *ngIf="cpu1Attached()">0x{{ toHex8(emu.cpu1Pc()) }}</span>
              <span class="hud-sub">{{ emu.cpu1StateLabel() }}</span>
            </div>

            <span class="hud-divider"></span>

            <div class="hud-item hud-meta">
              <span class="hud-value font-mono">{{ formattedCycles() }}</span>
              <span class="hud-sub font-mono">{{ pacingText() }}</span>
            </div>
          </ng-container>

          <ng-container *ngIf="!isConnected()">
            <div class="hud-offline-wrap" (click)="copyLaunchCommand()">
              <span class="status-dot"></span>
              <span class="offline-headline">Emulator Backend Disconnected</span>
              <span class="offline-sub">• Click to copy startup command</span>
            </div>
          </ng-container>
        </div>
      </div>

      <!-- Right: Transport Controls & Workbench Utilities -->
      <div class="toolbar-section toolbar-right">
        <!-- Segmented Transport Controls -->
        <div class="transport-segment">
          <button
            type="button"
            class="xcode-btn play-btn"
            [class.active]="isRunning()"
            [disabled]="!isConnected()"
            (click)="toggleRun()"
            [title]="isRunning() ? 'Pause Session' : 'Run Session'"
          >
            {{ isRunning() ? '⏸ Pause' : '▶ Run' }}
          </button>

          <button
            type="button"
            class="xcode-btn"
            [disabled]="!isConnected() || isRunning()"
            (click)="stepM85()"
            title="Single-step CPU0 (Cortex-M85)"
          >
            Step M85
          </button>

          <button
            *ngIf="cpu1Attached()"
            type="button"
            class="xcode-btn"
            [disabled]="!isConnected() || isRunning()"
            (click)="stepM33()"
            title="Single-step CPU1 (Cortex-M33)"
          >
            Step M33
          </button>

          <button
            type="button"
            class="xcode-btn"
            [disabled]="!isConnected()"
            (click)="reset()"
            title="Seek Session Origin (t=0)"
          >
            ↺
          </button>
        </div>

        <div class="v-sep"></div>

        <!-- Timeline DAG Drawer Toggle -->
        <button
          type="button"
          class="xcode-btn"
          [class.active]="dagOpen()"
          (click)="toggleDag()"
          title="Toggle Time-Travel Execution DAG"
        >
          Timeline
        </button>

        <!-- Actor Attribution Mode -->
        <button
          type="button"
          class="xcode-btn actor-btn"
          [class.agent]="actorMode() === 'agent'"
          (click)="toggleActor()"
          title="Actor attribution recorded on mutations and forks"
        >
          {{ actorMode() === 'human' ? '👤 Human' : '🤖 Agent' }}
        </button>

        <!-- macOS Theme Toggle (Sun / Moon) -->
        <button
          type="button"
          class="xcode-btn icon-only"
          (click)="toggleTheme()"
          [title]="isDark() ? 'Switch to macOS Light Theme' : 'Switch to Xcode Dark Theme'"
        >
          {{ isDark() ? '☀️' : '🌙' }}
        </button>
      </div>
    </header>
  `,
  styles: [`
    .xcode-toolbar {
      height: 44px;
      min-height: 44px;
      max-height: 44px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 14px;
      background: var(--bg-surface);
      border-bottom: 1px solid var(--border-subtle);
      user-select: none;
      position: relative;
      z-index: 50;
      gap: 12px;
    }

    .toolbar-section {
      display: flex;
      align-items: center;
      gap: 10px;
    }

    .toolbar-left {
      min-width: 250px;
    }

    .app-identity {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .app-icon {
      width: 26px;
      height: 26px;
      background: linear-gradient(135deg, var(--accent-blue), #5856d6);
      color: #ffffff;
      font-weight: 700;
      font-size: 11px;
      display: flex;
      align-items: center;
      justify-content: center;
      border-radius: var(--radius-md);
      letter-spacing: 0.04em;
    }

    .app-titles {
      display: flex;
      align-items: baseline;
      gap: 6px;
    }

    .app-name {
      font-size: 13px;
      font-weight: 600;
      color: var(--text-primary);
      letter-spacing: -0.01em;
    }

    .target-chip {
      font-size: 10px;
      font-weight: 500;
      padding: 1px 5px;
      border-radius: var(--radius-sm);
      background: var(--border-subtle);
      color: var(--text-secondary);
      font-family: var(--font-mono);
    }

    .conn-anchor {
      position: relative;
    }

    .conn-pill-btn {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 3px 8px;
      background: var(--border-subtle);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-xl);
      color: var(--text-secondary);
      font-size: 11px;
      cursor: pointer;
      transition: background 0.15s, border-color 0.15s;
    }

    .conn-pill-btn:hover {
      background: var(--bg-surface-elevated);
      border-color: var(--border-strong);
      color: var(--text-primary);
    }

    .status-dot {
      width: 7px;
      height: 7px;
      border-radius: 50%;
      background: var(--accent-amber);
    }
    .status-dot.online {
      background: var(--accent-green);
    }
    .status-dot.busy {
      background: var(--accent-blue);
      animation: pulse 1s infinite alternate;
    }

    @keyframes pulse {
      from { opacity: 0.4; }
      to { opacity: 1; }
    }

    /* Center Activity HUD */
    .toolbar-center {
      flex: 1;
      justify-content: center;
      max-width: 540px;
    }

    .activity-hud {
      width: 100%;
      height: 30px;
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-md);
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 0 12px;
      gap: 12px;
      transition: border-color 0.15s;
    }

    .activity-hud.running {
      border-color: var(--accent-blue-subtle);
    }

    .hud-item {
      display: flex;
      align-items: baseline;
      gap: 6px;
    }
    .hud-item.dimmed {
      opacity: 0.4;
    }

    .hud-core-label {
      font-size: 10px;
      font-weight: 700;
      color: var(--accent-blue);
      letter-spacing: 0.04em;
    }

    .hud-value {
      font-size: 11px;
      color: var(--text-primary);
    }

    .hud-sub {
      font-size: 10px;
      color: var(--text-secondary);
    }

    .hud-divider {
      width: 1px;
      height: 14px;
      background: var(--border-subtle);
    }

    .hud-offline-wrap {
      display: flex;
      align-items: center;
      gap: 6px;
      cursor: pointer;
      font-size: 11px;
    }

    .offline-headline {
      color: var(--accent-amber);
      font-weight: 500;
    }
    .offline-sub {
      color: var(--text-secondary);
    }

    /* Right Section: Buttons */
    .toolbar-right {
      min-width: 250px;
      justify-content: flex-end;
    }

    .transport-segment {
      display: flex;
      align-items: center;
      background: var(--bg-well);
      padding: 2px;
      border-radius: var(--radius-md);
      border: 1px solid var(--border-subtle);
      gap: 2px;
    }

    .xcode-btn {
      background: transparent;
      border: none;
      color: var(--text-primary);
      padding: 4px 8px;
      border-radius: var(--radius-sm);
      font-size: 11px;
      font-weight: 500;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 4px;
      transition: background 0.12s, color 0.12s;
    }

    .xcode-btn:hover:not(:disabled) {
      background: var(--bg-surface-elevated);
    }

    .xcode-btn:disabled {
      opacity: 0.35;
      cursor: not-allowed;
    }

    .xcode-btn.active {
      background: var(--accent-blue-subtle);
      color: var(--accent-blue);
    }

    .xcode-btn.play-btn.active {
      background: var(--accent-blue);
      color: #ffffff;
    }

    .xcode-btn.icon-only {
      padding: 4px 6px;
      font-size: 12px;
    }

    .v-sep {
      width: 1px;
      height: 18px;
      background: var(--border-subtle);
    }

    /* Settings Popover */
    .settings-popover {
      position: absolute;
      top: 34px;
      left: 0;
      width: 320px;
      background: var(--bg-surface);
      border: 1px solid var(--border-strong);
      border-radius: var(--radius-lg);
      box-shadow: 0 10px 28px rgba(0, 0, 0, 0.35);
      padding: 12px;
      display: flex;
      flex-direction: column;
      gap: 10px;
      z-index: 100;
    }

    .popover-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 12px;
      font-weight: 600;
      color: var(--text-primary);
    }

    .close-btn {
      background: transparent;
      border: none;
      color: var(--text-secondary);
      cursor: pointer;
      font-size: 12px;
    }

    .input-label {
      font-size: 11px;
      color: var(--text-secondary);
      margin-bottom: 4px;
      display: block;
    }

    .input-row {
      display: flex;
      gap: 6px;
    }

    .xcode-input {
      flex: 1;
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      color: var(--text-primary);
      padding: 5px 8px;
      font-size: 11px;
      font-family: var(--font-mono);
    }

    .xcode-btn.destructive {
      background: var(--accent-red);
      color: #ffffff;
    }

    .cmd-help {
      margin-top: 8px;
      border-top: 1px solid var(--border-subtle);
      padding-top: 8px;
      display: flex;
      flex-direction: column;
      gap: 4px;
    }

    .cmd-label {
      font-size: 10px;
      color: var(--text-secondary);
    }

    .cmd-code {
      font-size: 10px;
      font-family: var(--font-mono);
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      padding: 4px 6px;
      cursor: pointer;
      color: var(--accent-amber);
      word-break: break-all;
    }

    .copy-hint {
      font-size: 9px;
      color: var(--text-tertiary);
    }
  `]
})
export class ConnectionBarComponent {
  public emu = inject(EmulatorService);

  public urlInput = signal<string>(this.emu.serverUrl());
  public showSettings = signal<boolean>(false);
  public copied = signal<boolean>(false);

  public state = this.emu.connectionState;
  public actorMode = this.emu.actorMode;
  public dagOpen = this.emu.dagDrawerOpen;

  public isConnected = computed(() => this.state() === 'connected');
  public isConnecting = computed(() => this.state() === 'connecting');
  public isRunning = computed(() => this.emu.executionStatus() === 'running');
  public cpu1Attached = this.emu.cpu1Attached;
  public isDark = computed(() => this.emu.currentTheme() === 'dark');

  public formattedCycles = computed(() => {
    const r = this.emu.currentR();
    return `${r.toLocaleString()} cyc`;
  });

  public pacingText = computed(() => {
    const ratio = this.emu.pacingRatio();
    if (ratio === null) return '1.00x';
    return `${ratio.toFixed(2)}x`;
  });

  public launchCommand = computed(() => {
    const raw = this.urlInput().trim();
    const hostPort = raw.replace(/^wss?:\/\//i, '') || '127.0.0.1:4567';
    return `ra8_emulator serve --listen tcp:${hostPort}`;
  });

  public toHex8(val: number): string {
    return (val >>> 0).toString(16).padStart(8, '0');
  }

  public copyLaunchCommand(): void {
    void navigator.clipboard?.writeText(this.launchCommand());
    this.copied.set(true);
    setTimeout(() => this.copied.set(false), 1800);
  }

  public applyConnection(): void {
    if (this.isConnected()) {
      this.emu.disconnect();
    } else {
      void this.emu.connect(this.urlInput());
    }
    this.showSettings.set(false);
  }

  public toggleRun(): void {
    if (this.isRunning()) {
      void this.emu.pause();
    } else {
      void this.emu.run();
    }
  }

  public stepM85(): void {
    void this.emu.step(Core.Cpu0);
  }

  public stepM33(): void {
    void this.emu.step(Core.Cpu1);
  }

  public reset(): void {
    void this.emu.reset();
  }

  public toggleActor(): void {
    this.emu.actorMode.set(this.actorMode() === 'human' ? 'agent' : 'human');
  }

  public toggleDag(): void {
    this.emu.dagDrawerOpen.update((v) => !v);
  }

  public toggleTheme(): void {
    this.emu.toggleTheme();
  }
}
