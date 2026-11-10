import { Component, inject, computed, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { EmulatorService } from '../../services/emulator.service';

@Component({
  selector: 'app-connection-bar',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="top-bar">
      <!-- Brand Identity -->
      <div class="brand">
        <div class="chip-badge">RA8</div>
        <div class="brand-meta">
          <span class="brand-title">RA8 Emulator Workbench</span>
          <span class="brand-sub">Dual-Core Cortex-M85 / M33 • Hardware &amp; Time-Travel Fabric</span>
        </div>
      </div>

      <!-- Center: Unified Connection / Offline Pill (Single-line, click-to-copy CLI command) -->
      <div class="status-center">
        <button
          *ngIf="!isConnected()"
          type="button"
          class="offline-pill"
          [class.is-error]="state() === 'error'"
          (click)="copyLaunchCommand()"
          title="Click to copy launch command (Offline PWA shell active; live emulation requires backend)"
        >
          <span class="pill-dot"></span>
          <span class="pill-state">{{ isConnecting() ? 'Connecting…' : 'Offline' }}</span>
          <span class="pill-sep">•</span>
          <span class="pill-cmd">Run: <code>{{ launchCommand() }}</code></span>
          <span class="copy-tag">{{ copied() ? 'Copied ✓' : '📋' }}</span>
        </button>

        <div *ngIf="isConnected()" class="online-pill">
          <span class="pill-dot online"></span>
          <span>Connected</span>
          <span class="pill-sep">•</span>
          <code>{{ emu.serverUrl() }}</code>
          <span class="pill-sep" *ngIf="boardPanelLabel()">•</span>
          <span class="panel-tag" *ngIf="boardPanelLabel()">{{ boardPanelLabel() }}</span>
        </div>
      </div>

      <!-- Right: Actor Mode, DAG Toggle, & Endpoint Controls -->
      <div class="header-actions">
        <button
          type="button"
          class="actor-btn"
          [class.agent]="actorMode() === 'agent'"
          (click)="toggleActor()"
          title="Attribution tag recorded on interactive mutations and timeline forks"
        >
          <span>{{ actorMode() === 'human' ? '👤 Human' : '🤖 Agent' }}</span>
        </button>

        <button
          type="button"
          class="dag-toggle-btn"
          [class.active]="dagOpen()"
          (click)="toggleDag()"
          title="Toggle Right-Opening Time-Travel Execution DAG"
        >
          <span>🌿 Timeline DAG</span>
          <span class="lane-count">{{ laneCount() }}</span>
        </button>

        <div class="url-group">
          <span class="ws-tag">WS</span>
          <input
            type="text"
            class="url-input"
            placeholder="ws://127.0.0.1:4567"
            [ngModel]="urlInput()"
            (ngModelChange)="urlInput.set($event)"
            [disabled]="isConnecting() || isConnected()"
            (keydown.enter)="toggleConnection()"
          />
          <button
            type="button"
            class="conn-btn"
            [class.connected]="isConnected()"
            [class.connecting]="isConnecting()"
            (click)="toggleConnection()"
          >
            {{ isConnecting() ? '…' : isConnected() ? 'Disconnect' : 'Connect' }}
          </button>
        </div>
      </div>
    </div>
  `,
  styles: [`
    .top-bar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      padding: 8px 16px;
      background: linear-gradient(180deg, rgba(15, 23, 42, 0.95), rgba(9, 13, 22, 0.98));
      border-bottom: 1px solid rgba(255, 255, 255, 0.08);
      box-shadow: inset 0 1px 0 0 rgba(255, 255, 255, 0.05);
      flex-wrap: wrap;
    }

    .brand {
      display: flex;
      align-items: center;
      gap: 10px;
    }

    .chip-badge {
      background: linear-gradient(135deg, #0284c7 0%, #0f766e 100%);
      color: #f8fafc;
      font-weight: 800;
      font-size: 0.78rem;
      padding: 5px 8px;
      border-radius: 5px;
      letter-spacing: 0.06em;
      border: 1px solid rgba(255, 255, 255, 0.18);
      box-shadow: 0 2px 8px rgba(2, 132, 199, 0.28);
    }

    .brand-meta {
      display: flex;
      flex-direction: column;
      gap: 1px;
    }

    .brand-title {
      font-size: 0.88rem;
      font-weight: 700;
      color: #f8fafc;
      letter-spacing: -0.01em;
    }

    .brand-sub {
      font-size: 0.68rem;
      color: #94a3b8;
    }

    .status-center {
      display: flex;
      align-items: center;
      justify-content: center;
      flex: 1;
      min-width: 260px;
    }

    .offline-pill,
    .online-pill {
      display: inline-flex;
      align-items: center;
      gap: 7px;
      padding: 4px 11px;
      border-radius: 999px;
      font-size: 0.72rem;
      line-height: 1.2;
      border: 1px solid rgba(255, 255, 255, 0.1);
      background: rgba(15, 23, 42, 0.85);
      color: #cbd5e1;
      transition: border-color 0.15s, background 0.15s;
    }

    .offline-pill {
      cursor: pointer;
    }
    .offline-pill:hover {
      border-color: rgba(56, 189, 248, 0.45);
      background: rgba(30, 41, 59, 0.9);
    }
    .offline-pill.is-error {
      border-color: rgba(245, 158, 11, 0.35);
    }

    .pill-dot {
      width: 7px;
      height: 7px;
      border-radius: 50%;
      background: #f59e0b;
      flex-shrink: 0;
    }
    .pill-dot.online {
      background: #22c55e;
      box-shadow: 0 0 8px #22c55e;
    }

    .pill-state {
      font-weight: 600;
      color: #fbbf24;
    }

    .pill-sep {
      color: #475569;
    }

    .pill-cmd code,
    .online-pill code {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.69rem;
      color: #38bdf8;
    }

    .copy-tag {
      font-size: 0.68rem;
      color: #94a3b8;
      padding-left: 2px;
    }

    .panel-tag {
      color: #34d399;
      font-weight: 600;
      font-size: 0.69rem;
    }

    .header-actions {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
    }

    .actor-btn,
    .dag-toggle-btn {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 4px 10px;
      border-radius: 6px;
      font-size: 0.72rem;
      font-weight: 600;
      background: rgba(30, 41, 59, 0.7);
      color: #cbd5e1;
      border: 1px solid rgba(255, 255, 255, 0.09);
      cursor: pointer;
      transition: all 0.15s;
    }
    .actor-btn:hover,
    .dag-toggle-btn:hover {
      background: rgba(51, 65, 85, 0.85);
      color: #f8fafc;
    }
    .actor-btn.agent {
      border-color: rgba(168, 85, 247, 0.45);
      color: #e9d5ff;
      background: rgba(88, 28, 135, 0.3);
    }
    .dag-toggle-btn.active {
      border-color: rgba(56, 189, 248, 0.55);
      background: rgba(2, 132, 199, 0.22);
      color: #38bdf8;
    }

    .lane-count {
      background: rgba(15, 23, 42, 0.9);
      padding: 0 5px;
      border-radius: 999px;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.66rem;
      color: #38bdf8;
    }

    .url-group {
      display: inline-flex;
      align-items: center;
      background: #090d16;
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 6px;
      overflow: hidden;
    }

    .ws-tag {
      font-size: 0.64rem;
      font-weight: 700;
      color: #64748b;
      padding: 4px 7px;
      background: rgba(30, 41, 59, 0.55);
      border-right: 1px solid rgba(255, 255, 255, 0.07);
    }

    .url-input {
      background: transparent;
      border: none;
      color: #f1f5f9;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.72rem;
      padding: 4px 8px;
      width: 155px;
      outline: none;
    }
    .url-input:disabled {
      color: #64748b;
    }

    .conn-btn {
      background: #0284c7;
      color: #fff;
      border: none;
      padding: 5px 11px;
      font-size: 0.72rem;
      font-weight: 600;
      cursor: pointer;
      transition: background 0.15s;
    }
    .conn-btn:hover { background: #0369a1; }
    .conn-btn.connected { background: #dc2626; }
    .conn-btn.connected:hover { background: #b91c1c; }
    .conn-btn.connecting { background: #d97706; cursor: wait; }
  `]
})
export class ConnectionBarComponent {
  public emu = inject(EmulatorService);

  public urlInput = signal<string>(this.emu.serverUrl());
  public copied = signal<boolean>(false);

  public state = this.emu.connectionState;
  public actorMode = this.emu.actorMode;
  public dagOpen = this.emu.dagDrawerOpen;

  public isConnected = computed(() => this.state() === 'connected');
  public isConnecting = computed(() => this.state() === 'connecting');

  public laneCount = computed(() => {
    const backend = this.emu.backendBranches();
    return backend.length > 0 ? backend.length : this.emu.sessionLanes().length;
  });

  public boardPanelLabel = computed(() => {
    const parts = this.emu.boardParts();
    if (!parts) return '';
    return parts.panel ? `${parts.panel} (${parts.panelWidth}×${parts.panelHeight})` : 'Headless Board';
  });

  public launchCommand = computed(() => {
    const raw = this.urlInput().trim();
    const hostPort = raw.replace(/^wss?:\/\//i, '') || '127.0.0.1:4567';
    return `ra8_emulator serve --listen tcp:${hostPort}`;
  });

  public copyLaunchCommand(): void {
    void navigator.clipboard?.writeText(this.launchCommand());
    this.copied.set(true);
    setTimeout(() => this.copied.set(false), 1800);
  }

  public toggleActor(): void {
    this.emu.actorMode.set(this.actorMode() === 'human' ? 'agent' : 'human');
  }

  public toggleDag(): void {
    this.emu.dagDrawerOpen.update((v) => !v);
  }

  public toggleConnection(): void {
    if (this.isConnected()) {
      this.emu.disconnect();
    } else {
      void this.emu.connect(this.urlInput());
    }
  }
}
