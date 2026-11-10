import {
  Component,
  ElementRef,
  ViewChild,
  inject,
  computed,
  signal,
  AfterViewChecked,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { EmulatorService } from '../../services/emulator.service';

@Component({
  selector: 'app-uart-terminal',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="terminal-pane">
      <!-- Terminal Controls Strip -->
      <div class="terminal-subtoolbar">
        <div class="sub-left">
          <span class="sub-label font-mono">{{ entries().length }} lines</span>
        </div>
        <div class="sub-right">
          <label class="autoscroll-label">
            <input
              type="checkbox"
              [ngModel]="autoScroll()"
              (ngModelChange)="autoScroll.set($event)"
            />
            <span>Autoscroll</span>
          </label>
          <button type="button" class="tool-btn" (click)="copyAll()">Copy</button>
          <button type="button" class="tool-btn" (click)="clear()">Clear</button>
        </div>
      </div>

      <!-- Console Body -->
      <div #scrollContainer class="terminal-body font-mono">
        <div *ngIf="entries().length === 0" class="empty-terminal">
          Awaiting serial output on SCI8 console...
        </div>

        <div *ngFor="let item of entries()" class="terminal-line" [class.input-line]="item.isInput">
          <span class="line-time">[{{ item.time }}]</span>
          <span class="line-prefix">{{ item.isInput ? 'TX ▶' : 'RX ◀' }}</span>
          <span class="line-text">{{ item.text }}</span>
        </div>
      </div>

      <!-- Input Bar -->
      <div class="terminal-footer font-mono">
        <span class="prompt">TX &gt;</span>
        <input
          type="text"
          class="terminal-input font-mono"
          placeholder="Transmit line to guest firmware (Enter to send)..."
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
    .terminal-pane {
      height: 100%;
      display: flex;
      flex-direction: column;
      overflow: hidden;
      background: var(--bg-surface);
    }

    .terminal-subtoolbar {
      height: 26px;
      min-height: 26px;
      background: var(--bg-surface);
      border-bottom: 1px solid var(--border-subtle);
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 10px;
      flex-shrink: 0;
    }

    .sub-left, .sub-right {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .sub-label {
      font-size: 10px;
      color: var(--text-tertiary);
    }

    .autoscroll-label {
      display: inline-flex;
      align-items: center;
      gap: 4px;
      font-size: 10px;
      color: var(--text-secondary);
      cursor: pointer;
    }

    .tool-btn {
      background: transparent;
      border: 1px solid var(--border-subtle);
      color: var(--text-secondary);
      border-radius: var(--radius-sm);
      font-size: 10px;
      font-weight: 500;
      padding: 1px 6px;
      cursor: pointer;
    }
    .tool-btn:hover {
      background: var(--bg-well);
      color: var(--text-primary);
    }

    .terminal-body {
      flex: 1;
      min-height: 0;
      overflow-y: auto;
      padding: 6px 10px;
      font-size: 11px;
      line-height: 1.45;
      background: var(--bg-well);
    }

    .empty-terminal {
      color: var(--text-tertiary);
      padding: 10px 0;
    }

    .terminal-line {
      display: flex;
      gap: 6px;
      word-break: break-all;
      color: var(--accent-blue);
    }
    .terminal-line.input-line {
      color: var(--accent-green);
    }

    .line-time {
      color: var(--text-tertiary);
      font-size: 10px;
      user-select: none;
    }

    .line-prefix {
      color: var(--text-secondary);
      font-size: 10px;
      user-select: none;
    }

    .line-text {
      white-space: pre-wrap;
    }

    .terminal-footer {
      height: 28px;
      min-height: 28px;
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 0 10px;
      background: var(--bg-surface);
      border-top: 1px solid var(--border-subtle);
      flex-shrink: 0;
    }

    .prompt {
      font-size: 10px;
      color: var(--accent-green);
      font-weight: 600;
    }

    .terminal-input {
      flex: 1;
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      color: var(--text-primary);
      font-size: 11px;
      padding: 2px 6px;
      outline: none;
    }
    .terminal-input:focus {
      border-color: var(--accent-blue);
    }
    .terminal-input:disabled {
      opacity: 0.45;
      cursor: not-allowed;
    }

    .send-btn {
      background: var(--accent-blue);
      border: none;
      border-radius: var(--radius-sm);
      color: #ffffff;
      font-size: 10px;
      font-weight: 600;
      padding: 3px 8px;
      cursor: pointer;
    }
    .send-btn:disabled {
      opacity: 0.35;
      cursor: not-allowed;
    }
  `]
})
export class UartTerminalComponent implements AfterViewChecked {
  @ViewChild('scrollContainer') private scrollContainer?: ElementRef<HTMLDivElement>;

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
    const all = this.entries()
      .map((e) => `[${e.time}] ${e.isInput ? 'TX: ' : 'RX: '}${e.text}`)
      .join('\n');
    void navigator.clipboard?.writeText(all);
  }
}
