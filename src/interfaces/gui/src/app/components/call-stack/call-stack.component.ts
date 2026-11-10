import { Component, inject, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { EmulatorService } from '../../services/emulator.service';
import { StackFrame } from 'ra8-rpc-client';

@Component({
  selector: 'app-call-stack',
  standalone: true,
  imports: [CommonModule],
  template: `
    <div class="stack-card">
      <div class="card-header">
        <span class="title">CALL STACK (BACKTRACE)</span>
        <button
          type="button"
          class="refresh-btn"
          (click)="refresh()"
          [disabled]="!isConnected()"
          title="Refresh Call Stack"
        >
          ↻
        </button>
      </div>

      <div class="frames-list">
        <div *ngIf="frames().length === 0" class="empty-state">
          No stack frames available (Core running or halted without debug frames)
        </div>

        <div
          *ngFor="let frame of frames(); let i = index"
          class="frame-item"
          [class.innermost]="i === 0"
        >
          <span class="frame-idx">#{{ i }}</span>
          <div class="frame-details">
            <div class="fn-name">{{ frame.name || '??' }}()</div>
            <div class="file-info" *ngIf="frame.file">
              {{ frame.file }}:{{ frame.line }}
            </div>
          </div>
          <span class="frame-pc">0x{{ toHex(frame.pc) }}</span>
        </div>
      </div>
    </div>
  `,
  styles: [`
    .stack-card {
      background: var(--bg-secondary);
      border: 1px solid var(--border-color);
      border-radius: 8px;
      overflow: hidden;
      display: flex;
      flex-direction: column;
    }

    .card-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 6px 10px;
      background: var(--bg-tertiary);
      border-bottom: 1px solid var(--border-color);
    }

    .title {
      font-size: 0.75rem;
      font-weight: 700;
      color: var(--text-primary);
    }

    .refresh-btn {
      background: transparent;
      border: none;
      color: var(--text-secondary);
      font-size: 0.9rem;
      cursor: pointer;
      line-height: 1;
    }
    .refresh-btn:disabled { opacity: 0.3; cursor: not-allowed; }

    .frames-list {
      padding: 6px;
      display: flex;
      flex-direction: column;
      gap: 4px;
      max-height: 220px;
      overflow-y: auto;
    }

    .empty-state {
      padding: 12px;
      text-align: center;
      font-size: 0.75rem;
      color: #64748b;
      font-style: italic;
    }

    .frame-item {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 4px 8px;
      background: #181b20;
      border: 1px solid #232730;
      border-radius: 4px;
      font-family: monospace;
      font-size: 0.75rem;
      cursor: pointer;
      transition: background 0.15s;
    }
    .frame-item:hover {
      background: #242933;
    }
    .frame-item.innermost {
      border-left: 3px solid #38bdf8;
    }

    .frame-idx {
      color: #64748b;
      font-weight: bold;
      min-width: 20px;
    }

    .frame-details {
      flex: 1;
      overflow: hidden;
      display: flex;
      flex-direction: column;
    }

    .fn-name {
      color: #f1f5f9;
      font-weight: 600;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .file-info {
      font-size: 0.65rem;
      color: #94a3b8;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .frame-pc {
      color: #38bdf8;
      font-size: 0.7rem;
    }
  `]
})
export class CallStackComponent {
  private emu = inject(EmulatorService);

  public isConnected = computed(() => this.emu.connectionState() === 'connected');
  public frames = computed<StackFrame[]>(() => {
    return this.emu.backtrace()?.frames ?? [];
  });

  public refresh(): void {
    void this.emu.refreshBacktrace();
  }

  public toHex(pc: number): string {
    return (pc >>> 0).toString(16).padStart(8, '0');
  }
}
