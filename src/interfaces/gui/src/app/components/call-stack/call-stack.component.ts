import { Component, inject, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { EmulatorService } from '../../services/emulator.service';
import { StackFrame } from 'ra8-rpc-client';

@Component({
  selector: 'app-call-stack',
  standalone: true,
  imports: [CommonModule],
  template: `
    <div class="stack-pane">
      <!-- Sub-Toolbar -->
      <div class="stack-subtoolbar">
        <span class="sub-label">Backtrace Frames</span>
        <button
          type="button"
          class="refresh-btn"
          (click)="refresh()"
          [disabled]="!isConnected()"
          title="Refresh call stack"
        >
          ↻
        </button>
      </div>

      <!-- Frames List -->
      <div class="stacks-body">
        <!-- CPU0 Stack -->
        <div *ngIf="showCpu0()" class="stack-lane">
          <div class="lane-label m85">CPU0 • Cortex-M85 ({{ cpu0Frames().length }} frames)</div>
          <div *ngIf="cpu0Frames().length === 0" class="empty-state">
            No unwound frames (halt CPU0 to inspect call chain)
          </div>
          <div
            *ngFor="let frame of cpu0Frames(); let i = index"
            class="frame-item font-mono"
            [class.innermost]="i === 0"
          >
            <span class="frame-idx">#{{ i }}</span>
            <div class="frame-details">
              <span class="fn-name">{{ frame.name || '??' }}()</span>
              <span class="file-info" *ngIf="frame.file">{{ frame.file }}:{{ frame.line }}</span>
            </div>
            <span class="frame-pc">0x{{ toHex(frame.pc) }}</span>
          </div>
        </div>

        <!-- CPU1 Stack -->
        <div *ngIf="showCpu1() && emu.cpu1Attached()" class="stack-lane">
          <div class="lane-label m33">CPU1 • Cortex-M33 ({{ cpu1Frames().length }} frames)</div>
          <div *ngIf="cpu1Frames().length === 0" class="empty-state">
            No unwound M33 frames
          </div>
          <div
            *ngFor="let frame of cpu1Frames(); let i = index"
            class="frame-item font-mono"
            [class.innermost]="i === 0"
          >
            <span class="frame-idx">#{{ i }}</span>
            <div class="frame-details">
              <span class="fn-name">{{ frame.name || '??' }}()</span>
              <span class="file-info" *ngIf="frame.file">{{ frame.file }}:{{ frame.line }}</span>
            </div>
            <span class="frame-pc">0x{{ toHex(frame.pc) }}</span>
          </div>
        </div>
      </div>
    </div>
  `,
  styles: [`
    .stack-pane {
      height: 100%;
      display: flex;
      flex-direction: column;
      overflow: hidden;
      background: var(--bg-surface);
    }

    .stack-subtoolbar {
      height: 28px;
      min-height: 28px;
      background: var(--bg-surface);
      border-bottom: 1px solid var(--border-subtle);
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 10px;
      flex-shrink: 0;
    }

    .sub-label {
      font-size: 10px;
      color: var(--text-secondary);
      font-weight: 500;
    }

    .refresh-btn {
      background: transparent;
      border: none;
      color: var(--text-secondary);
      font-size: 12px;
      cursor: pointer;
      padding: 2px 6px;
      border-radius: var(--radius-sm);
    }
    .refresh-btn:hover:not(:disabled) {
      color: var(--text-primary);
      background: var(--border-subtle);
    }
    .refresh-btn:disabled {
      opacity: 0.35;
      cursor: not-allowed;
    }

    .stacks-body {
      flex: 1;
      min-height: 0;
      overflow-y: auto;
      display: flex;
      flex-direction: column;
    }

    .stack-lane {
      padding: 4px 8px;
      display: flex;
      flex-direction: column;
      gap: 3px;
    }

    .stack-lane + .stack-lane {
      border-top: 1px solid var(--border-subtle);
    }

    .lane-label {
      font-size: 10px;
      font-weight: 600;
      padding: 2px 4px;
    }
    .lane-label.m85 { color: var(--accent-blue); }
    .lane-label.m33 { color: var(--accent-purple); }

    .empty-state {
      padding: 16px 8px;
      font-size: 11px;
      color: var(--text-tertiary);
      text-align: center;
    }

    .frame-item {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 4px 8px;
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      font-size: 11px;
    }

    .frame-item.innermost {
      border-left: 2px solid var(--accent-blue);
    }

    .frame-idx {
      color: var(--text-tertiary);
      font-weight: 700;
      width: 22px;
    }

    .frame-details {
      flex: 1;
      overflow: hidden;
      display: flex;
      flex-direction: column;
      gap: 1px;
    }

    .fn-name {
      color: var(--text-primary);
      font-weight: 600;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .file-info {
      font-size: 10px;
      color: var(--text-secondary);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .frame-pc {
      color: var(--accent-blue);
      font-size: 10px;
    }
  `]
})
export class CallStackComponent {
  public emu = inject(EmulatorService);

  public isConnected = computed(() => this.emu.connectionState() === 'connected');
  public showCpu0 = computed(() => this.emu.inspectionMode() !== 'cpu1');
  public showCpu1 = computed(() => this.emu.inspectionMode() !== 'cpu0');

  public cpu0Frames = computed<StackFrame[]>(() => this.emu.cpu0Backtrace()?.frames ?? []);
  public cpu1Frames = computed<StackFrame[]>(() => this.emu.cpu1Backtrace()?.frames ?? []);

  public refresh(): void {
    void this.emu.refreshBacktrace();
  }

  public toHex(pc: number): string {
    return (pc >>> 0).toString(16).padStart(8, '0');
  }
}
