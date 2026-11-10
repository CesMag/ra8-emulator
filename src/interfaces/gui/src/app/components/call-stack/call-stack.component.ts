import { Component, inject, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { EmulatorService } from '../../services/emulator.service';
import { StackFrame } from 'ra8-rpc-client';

@Component({
  selector: 'app-call-stack',
  standalone: true,
  imports: [CommonModule],
  template: `
    <div class="pane-card">
      <div class="pane-header">
        <span class="pane-title">Call Stack Backtrace</span>
        <button
          type="button"
          class="refresh-btn"
          (click)="refresh()"
          [disabled]="!isConnected()"
          title="Refresh Dual-Core Call Stacks"
        >
          ↻
        </button>
      </div>

      <div class="stacks-body">
        <!-- CPU0 Stack -->
        <div *ngIf="showCpu0()" class="stack-lane">
          <div class="lane-label m85">CPU0 • Cortex-M85 ({{ cpu0Frames().length }} frames)</div>
          <div *ngIf="cpu0Frames().length === 0" class="empty-state">
            No unwound frames (halt CPU0 with debug symbols to inspect call chain)
          </div>
          <div
            *ngFor="let frame of cpu0Frames(); let i = index"
            class="frame-item"
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
            class="frame-item"
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
    .pane-card {
      background: linear-gradient(180deg, rgba(15, 23, 42, 0.84), rgba(6, 10, 19, 0.92));
      border: 1px solid rgba(255, 255, 255, 0.08);
      box-shadow: inset 0 1px 0 0 rgba(255, 255, 255, 0.06);
      border-radius: 10px;
      overflow: hidden;
      display: flex;
      flex-direction: column;
    }

    .pane-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 7px 12px;
      background: rgba(15, 23, 42, 0.55);
      border-bottom: 1px solid rgba(255, 255, 255, 0.07);
    }

    .pane-title {
      font-size: 0.8rem;
      font-weight: 600;
      color: #f1f5f9;
    }

    .refresh-btn {
      background: transparent;
      border: none;
      color: #94a3b8;
      font-size: 0.88rem;
      cursor: pointer;
    }
    .refresh-btn:disabled { opacity: 0.35; cursor: not-allowed; }

    .stacks-body {
      max-height: 200px;
      overflow-y: auto;
      display: flex;
      flex-direction: column;
    }

    .stack-lane {
      padding: 6px 8px;
      display: flex;
      flex-direction: column;
      gap: 4px;
    }
    .stack-lane + .stack-lane {
      border-top: 1px solid rgba(255, 255, 255, 0.07);
    }

    .lane-label {
      font-size: 0.66rem;
      font-weight: 600;
    }
    .lane-label.m85 { color: #38bdf8; }
    .lane-label.m33 { color: #c084fc; }

    .empty-state {
      padding: 8px 4px;
      font-size: 0.7rem;
      color: #64748b;
    }

    .frame-item {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 4px 8px;
      background: rgba(9, 13, 22, 0.68);
      border: 1px solid rgba(255, 255, 255, 0.06);
      border-radius: 5px;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.71rem;
    }
    .frame-item.innermost {
      border-left: 2px solid #38bdf8;
    }

    .frame-idx {
      color: #64748b;
      font-weight: 700;
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
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .file-info {
      font-size: 0.63rem;
      color: #94a3b8;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .frame-pc {
      color: #38bdf8;
      font-size: 0.68rem;
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
