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
      <!-- Brand & Title -->
      <div class="brand">
        <div class="chip-logo">RA8</div>
        <div class="brand-text">
          <span class="app-title">RA8 EMULATOR</span>
          <span class="app-subtitle">Cortex-M85 / M33 Debugger PWA</span>
        </div>
      </div>

      <!-- Connection Controls -->
      <div class="connection-section">
        <div class="url-input-group">
          <span class="protocol-prefix">WS</span>
          <input
            type="text"
            class="endpoint-input"
            placeholder="ws://127.0.0.1:4567"
            [ngModel]="urlInput()"
            (ngModelChange)="urlInput.set($event)"
            [disabled]="isConnecting() || isConnected()"
            (keydown.enter)="toggleConnection()"
          />
        </div>

        <button
          type="button"
          class="connect-btn"
          [class.connected]="isConnected()"
          [class.connecting]="isConnecting()"
          (click)="toggleConnection()"
        >
          <span *ngIf="isConnecting()">Connecting...</span>
          <span *ngIf="isConnected()">Disconnect</span>
          <span *ngIf="!isConnected() && !isConnecting()">Connect</span>
        </button>

        <div class="status-pill" [ngClass]="statusClass()">
          <span class="dot"></span>
          <span>{{ statusText() }}</span>
        </div>
      </div>
    </div>

    <!-- Offline / Disconnected Notice Banner -->
    <div *ngIf="!isConnected()" class="offline-banner">
      <span class="warn-icon">ℹ️</span>
      <div class="banner-content">
        <span class="banner-title">Offline App Shell Active</span>
        <span class="banner-desc">
          The debugger shell is running offline in your browser. Live dual-core emulation and hardware inspection require an active WebSocket connection to
          <code>ra8_emulator serve --listen tcp:127.0.0.1:4567</code>.
        </span>
      </div>
    </div>

    <!-- Error Banner -->
    <div *ngIf="errorMessage()" class="error-banner">
      <span class="error-icon">⚠️</span>
      <span class="error-text">{{ errorMessage() }}</span>
    </div>
  `,
  styles: [`
    .top-bar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 10px 16px;
      background: var(--bg-secondary);
      border-bottom: 1px solid var(--border-color);
      flex-wrap: wrap;
      gap: 12px;
    }

    .brand {
      display: flex;
      align-items: center;
      gap: 10px;
    }

    .chip-logo {
      background: linear-gradient(135deg, #0284c7 0%, #0369a1 100%);
      color: #fff;
      font-weight: 900;
      font-size: 0.85rem;
      padding: 4px 8px;
      border-radius: 4px;
      letter-spacing: 0.05em;
      box-shadow: 0 2px 4px rgba(0, 0, 0, 0.3);
    }

    .brand-text {
      display: flex;
      flex-direction: column;
    }

    .app-title {
      font-weight: 800;
      font-size: 0.95rem;
      letter-spacing: 0.05em;
      color: var(--text-primary);
    }

    .app-subtitle {
      font-size: 0.65rem;
      color: var(--text-secondary);
    }

    .connection-section {
      display: flex;
      align-items: center;
      gap: 10px;
    }

    .url-input-group {
      display: flex;
      align-items: center;
      background: #0f172a;
      border: 1px solid var(--border-color);
      border-radius: 4px;
      overflow: hidden;
    }

    .protocol-prefix {
      background: #1e293b;
      color: #94a3b8;
      font-size: 0.65rem;
      font-weight: 700;
      padding: 4px 6px;
      border-right: 1px solid var(--border-color);
    }

    .endpoint-input {
      background: transparent;
      border: none;
      color: #f1f5f9;
      font-family: monospace;
      font-size: 0.75rem;
      padding: 4px 8px;
      width: 170px;
      outline: none;
    }

    .endpoint-input:disabled {
      color: #64748b;
    }

    .connect-btn {
      background: #0284c7;
      color: #fff;
      border: none;
      border-radius: 4px;
      font-size: 0.75rem;
      font-weight: 600;
      padding: 5px 12px;
      cursor: pointer;
      transition: all 0.15s;
    }
    .connect-btn:hover { background: #0369a1; }

    .connect-btn.connected {
      background: #b91c1c;
    }
    .connect-btn.connected:hover { background: #991b1b; }

    .connect-btn.connecting {
      background: #d97706;
      cursor: wait;
    }

    .status-pill {
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 3px 8px;
      border-radius: 12px;
      font-size: 0.7rem;
      font-weight: 600;
      font-family: monospace;
    }

    .status-pill .dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
    }

    .pill-connected {
      background: rgba(34, 197, 94, 0.15);
      color: #4ade80;
    }
    .pill-connected .dot {
      background: #4ade80;
      box-shadow: 0 0 6px #4ade80;
    }

    .pill-connecting {
      background: rgba(245, 158, 11, 0.15);
      color: #fbbf24;
    }
    .pill-connecting .dot {
      background: #fbbf24;
      animation: pulse 1s infinite;
    }

    .pill-disconnected {
      background: rgba(148, 163, 184, 0.1);
      color: #94a3b8;
    }
    .pill-disconnected .dot {
      background: #64748b;
    }

    .pill-error {
      background: rgba(239, 68, 68, 0.15);
      color: #f87171;
    }
    .pill-error .dot {
      background: #ef4444;
    }

    .offline-banner {
      display: flex;
      align-items: flex-start;
      gap: 10px;
      background: #1e2533;
      border-bottom: 1px solid #2e3a4e;
      padding: 8px 16px;
      font-size: 0.75rem;
    }

    .warn-icon {
      font-size: 1rem;
    }

    .banner-content {
      display: flex;
      flex-direction: column;
      gap: 2px;
    }

    .banner-title {
      font-weight: 700;
      color: #38bdf8;
    }

    .banner-desc {
      color: #94a3b8;
      line-height: 1.4;
    }

    .banner-desc code {
      background: #0f172a;
      color: #e2e8f0;
      padding: 1px 4px;
      border-radius: 3px;
      font-family: monospace;
    }

    .error-banner {
      display: flex;
      align-items: center;
      gap: 8px;
      background: #381515;
      border-bottom: 1px solid #5c2222;
      padding: 6px 16px;
      font-size: 0.75rem;
      color: #fca5a5;
    }
  `]
})
export class ConnectionBarComponent {
  private emu = inject(EmulatorService);

  public urlInput = signal<string>(this.emu.serverUrl());
  public state = this.emu.connectionState;
  public errorMessage = this.emu.errorMessage;

  public isConnected = computed(() => this.state() === 'connected');
  public isConnecting = computed(() => this.state() === 'connecting');

  public statusText = computed(() => {
    switch (this.state()) {
      case 'connected': return 'ONLINE';
      case 'connecting': return 'CONNECTING';
      case 'error': return 'FAILED';
      default: return 'OFFLINE';
    }
  });

  public statusClass = computed(() => {
    switch (this.state()) {
      case 'connected': return 'pill-connected';
      case 'connecting': return 'pill-connecting';
      case 'error': return 'pill-error';
      default: return 'pill-disconnected';
    }
  });

  public toggleConnection(): void {
    if (this.isConnected()) {
      this.emu.disconnect();
    } else {
      void this.emu.connect(this.urlInput());
    }
  }
}
