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
    <div class="terminal-card">
      <div class="terminal-header">
        <div class="header-left">
          <span class="pane-title">Serial Console (SCI8 UART)</span>
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
          <button type="button" class="tool-btn" (click)="copyAll()">Copy</button>
          <button type="button" class="tool-btn" (click)="clear()">Clear</button>
        </div>
      </div>

      <div #scrollContainer class="terminal-body">
        <div *ngIf="entries().length === 0" class="empty-terminal">
          Awaiting serial output on SCI8 console...
        </div>

        <div *ngFor="let item of entries()" class="terminal-line" [class.input-line]="item.isInput">
          <span class="line-time">[{{ item.time }}]</span>
          <span class="line-prefix">{{ item.isInput ? 'TX ▶' : 'RX ◀' }}</span>
          <span class="line-text">{{ item.text }}</span>
        </div>
      </div>

      <div class="terminal-footer">
        <span class="prompt">SCI8 TX &gt;</span>
        <input
          type="text"
          class="terminal-input"
          placeholder="Transmit serial line to guest firmware (Enter to send)..."
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
      background: linear-gradient(180deg, rgba(13, 17, 23, 0.94), rgba(6, 9, 15, 0.98));
      border: 1px solid rgba(255, 255, 255, 0.08);
      box-shadow: inset 0 1px 0 0 rgba(255, 255, 255, 0.06);
      border-radius: 10px;
      overflow: hidden;
      display: flex;
      flex-direction: column;
    }

    .terminal-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 7px 12px;
      background: rgba(15, 23, 42, 0.55);
      border-bottom: 1px solid rgba(255, 255, 255, 0.07);
      flex-wrap: wrap;
      gap: 8px;
    }

    .header-left,
    .header-right {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .pane-title {
      font-size: 0.8rem;
      font-weight: 600;
      color: #f1f5f9;
    }

    .badge {
      font-size: 0.66rem;
      color: #94a3b8;
      background: rgba(15, 23, 42, 0.8);
      border: 1px solid rgba(255, 255, 255, 0.07);
      padding: 1px 6px;
      border-radius: 4px;
      font-family: "JetBrains Mono", monospace;
    }

    .autoscroll-toggle {
      display: inline-flex;
      align-items: center;
      gap: 5px;
      font-size: 0.7rem;
      color: #94a3b8;
      cursor: pointer;
    }

    .tool-btn {
      background: rgba(30, 41, 59, 0.75);
      color: #cbd5e1;
      border: 1px solid rgba(255, 255, 255, 0.09);
      border-radius: 5px;
      font-size: 0.69rem;
      font-weight: 600;
      padding: 2px 8px;
      cursor: pointer;
    }
    .tool-btn:hover { background: rgba(51, 65, 85, 0.9); color: #fff; }

    .terminal-body {
      height: 165px;
      overflow-y: auto;
      padding: 8px 12px;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.73rem;
      line-height: 1.45;
      background: #06090f;
    }

    .empty-terminal {
      color: #64748b;
      padding: 12px 0;
    }

    .terminal-line {
      display: flex;
      gap: 7px;
      word-break: break-all;
      color: #7dd3fc;
    }
    .terminal-line.input-line {
      color: #86efac;
    }

    .line-time {
      color: #475569;
      font-size: 0.65rem;
      user-select: none;
    }

    .line-prefix {
      color: #64748b;
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
      background: rgba(15, 23, 42, 0.6);
      border-top: 1px solid rgba(255, 255, 255, 0.07);
    }

    .prompt {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.71rem;
      color: #34d399;
      font-weight: 600;
    }

    .terminal-input {
      flex: 1;
      background: #06090f;
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 5px;
      color: #f1f5f9;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.73rem;
      padding: 4px 8px;
      outline: none;
    }
    .terminal-input:focus { border-color: #38bdf8; }
    .terminal-input:disabled { opacity: 0.45; cursor: not-allowed; }

    .send-btn {
      background: #0284c7;
      border: none;
      border-radius: 5px;
      color: #fff;
      font-size: 0.72rem;
      font-weight: 600;
      padding: 4px 12px;
      cursor: pointer;
    }
    .send-btn:disabled { opacity: 0.35; cursor: not-allowed; }
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
