import {
  Component,
  ElementRef,
  ViewChild,
  inject,
  computed,
  signal,
  effect,
  AfterViewChecked
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { EmulatorService, ConsoleEntry } from '../../services/emulator.service';

@Component({
  selector: 'app-uart-terminal',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="terminal-card">
      <div class="terminal-header">
        <div class="header-left">
          <span class="icon">📟</span>
          <span class="title">VIRTUAL UART SERIAL TERMINAL</span>
          <span class="badge">{{ entries().length }} lines</span>
        </div>
        <div class="header-right">
          <label class="autoscroll-toggle">
            <input
              type="checkbox"
              [ngModel]="autoScroll()"
              (ngModelChange)="autoScroll.set($event)"
            />
            <span>Autoscroll</span>
          </label>
          <button type="button" class="tool-btn" (click)="copyAll()" title="Copy to clipboard">
            📋 Copy
          </button>
          <button type="button" class="tool-btn" (click)="clear()" title="Clear terminal">
            🗑 Clear
          </button>
        </div>
      </div>

      <!-- Output Scrollback Area -->
      <div #scrollContainer class="terminal-body">
        <div *ngIf="entries().length === 0" class="empty-terminal">
          Awaiting UART serial output from firmware (Topic 0x0101)...
        </div>

        <div *ngFor="let item of entries()" class="terminal-line" [class.input-line]="item.isInput">
          <span class="line-time">[{{ item.time }}]</span>
          <span class="line-prefix">{{ item.isInput ? 'TX ▶ ' : 'RX ◀ ' }}</span>
          <span class="line-text">{{ item.text }}</span>
        </div>
      </div>

      <!-- Input Bar -->
      <div class="terminal-footer">
        <span class="prompt">TX ></span>
        <input
          type="text"
          class="terminal-input"
          placeholder="Send serial input to guest firmware (Enter to transmit)..."
          [ngModel]="inputText()"
          (ngModelChange)="inputText.set($event)"
          (keydown.enter)="send()"
          [disabled]="!isConnected()"
        />
        <button
          type="button"
          class="send-btn"
          (click)="send()"
          [disabled]="!isConnected() || !inputText().trim()"
        >
          Send
        </button>
      </div>
    </div>
  `,
  styles: [`
    .terminal-card {
      background: #0d1117;
      border: 1px solid var(--border-color);
      border-radius: 8px;
      overflow: hidden;
      display: flex;
      flex-direction: column;
    }

    .terminal-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 6px 12px;
      background: #161b22;
      border-bottom: 1px solid var(--border-color);
      flex-wrap: wrap;
      gap: 8px;
    }

    .header-left {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .title {
      font-size: 0.75rem;
      font-weight: 700;
      color: #c9d1d9;
    }

    .badge {
      font-size: 0.65rem;
      color: #8b949e;
      background: #21262d;
      padding: 1px 6px;
      border-radius: 4px;
      font-family: monospace;
    }

    .header-right {
      display: flex;
      align-items: center;
      gap: 10px;
    }

    .autoscroll-toggle {
      display: flex;
      align-items: center;
      gap: 4px;
      font-size: 0.7rem;
      color: #8b949e;
      cursor: pointer;
    }

    .tool-btn {
      background: #21262d;
      color: #c9d1d9;
      border: 1px solid #30363d;
      border-radius: 4px;
      font-size: 0.7rem;
      padding: 2px 8px;
      cursor: pointer;
    }
    .tool-btn:hover { background: #30363d; }

    .terminal-body {
      height: 180px;
      overflow-y: auto;
      padding: 8px 12px;
      font-family: 'JetBrains Mono', 'Fira Code', 'Consolas', monospace;
      font-size: 0.75rem;
      line-height: 1.4;
      background: #090d13;
    }

    .empty-terminal {
      color: #484f58;
      font-style: italic;
      padding: 16px 0;
    }

    .terminal-line {
      display: flex;
      gap: 6px;
      word-break: break-all;
      color: #58a6ff;
    }

    .terminal-line.input-line {
      color: #7ee787;
    }

    .line-time {
      color: #484f58;
      font-size: 0.65rem;
      user-select: none;
    }

    .line-prefix {
      color: #8b949e;
      font-size: 0.65rem;
      user-select: none;
    }

    .line-text {
      white-space: pre-wrap;
    }

    .terminal-footer {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 6px 12px;
      background: #161b22;
      border-top: 1px solid #30363d;
    }

    .prompt {
      font-family: monospace;
      font-size: 0.75rem;
      color: #7ee787;
      font-weight: bold;
    }

    .terminal-input {
      flex: 1;
      background: #0d1117;
      border: 1px solid #30363d;
      border-radius: 4px;
      color: #f0f6fc;
      font-family: monospace;
      font-size: 0.75rem;
      padding: 4px 8px;
      outline: none;
    }
    .terminal-input:focus {
      border-color: #58a6ff;
    }

    .send-btn {
      background: #238636;
      border: 1px solid #2ea043;
      border-radius: 4px;
      color: #fff;
      font-size: 0.75rem;
      font-weight: 600;
      padding: 4px 12px;
      cursor: pointer;
    }
    .send-btn:disabled { opacity: 0.4; cursor: not-allowed; }
  `]
})
export class UartTerminalComponent implements AfterViewChecked {
  @ViewChild('scrollContainer') private scrollContainer!: ElementRef<HTMLDivElement>;

  private emu = inject(EmulatorService);

  public autoScroll = signal<boolean>(true);
  public inputText = signal<string>('');
  public isConnected = computed(() => this.emu.connectionState() === 'connected');
  public entries = this.emu.consoleEntries;

  ngAfterViewChecked(): void {
    if (this.autoScroll() && this.scrollContainer) {
      const el = this.scrollContainer.nativeElement;
      el.scrollTop = el.scrollHeight;
    }
  }

  public send(): void {
    const text = this.inputText().trim();
    if (!text) return;
    void this.emu.sendConsoleInput(text);
    this.inputText.set('');
  }

  public clear(): void {
    this.emu.clearConsole();
  }

  public copyAll(): void {
    const all = this.entries().map(e => `[${e.time}] ${e.isInput ? 'TX: ' : 'RX: '}${e.text}`).join('\n');
    void navigator.clipboard.writeText(all);
  }
}
