import { Component, inject, computed, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import {
  EmulatorService,
  DagCheckpointNode,
  DagLaneView,
  forkReasonBadge,
} from '../../services/emulator.service';
import { Direction } from 'ra8-rpc-client';

@Component({
  selector: 'app-execution-dag',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <section *ngIf="emu.dagDrawerOpen()" class="dag-drawer">
      <div class="dag-header">
        <div class="dag-title-wrap">
          <span class="dag-title">Time-Travel Execution DAG</span>
          <span class="dag-mode-pill" [class.disk]="emu.historySupported()">
            {{ emu.historySupported() ? 'Persistent Rewind & Branch Router Active' : 'Live Exploratory Session Graph (pass --history-dir for hardware rewind)' }}
          </span>
          <span *ngIf="frameStatsText()" class="frame-stats">{{ frameStatsText() }}</span>
        </div>

        <div class="dag-controls">
          <button
            type="button"
            class="dag-btn"
            [disabled]="!isConnected()"
            (click)="playBack()"
            title="Play Recorded History Backward"
          >
            ⏪ Reverse Play
          </button>
          <button
            type="button"
            class="dag-btn"
            [disabled]="!isConnected()"
            (click)="playForward()"
            title="Play Recorded History Forward"
          >
            ⏩ Replay Fwd
          </button>

          <div class="seek-group">
            <input
              type="text"
              class="seek-input"
              placeholder="Seek: 0, 50ms, #4..."
              [ngModel]="seekTarget()"
              (ngModelChange)="seekTarget.set($event)"
              (keydown.enter)="runSeek()"
            />
            <button type="button" class="seek-btn" [disabled]="!isConnected()" (click)="runSeek()">
              Seek
            </button>
          </div>

          <button type="button" class="close-btn" (click)="close()">✕</button>
        </div>
      </div>

      <!-- Pending Hardware Fork Confirmation Bar (Method 0x0133 / 0x0134) -->
      <div *ngIf="pendingFork()" class="fork-confirm-bar">
        <span>
          <strong>Pending Timeline Bifurcation:</strong>
          Mutation [{{ badgeOf(pendingFork()!.reason) || 'W' }}] at branch #{{ pendingFork()!.branch }} (r={{ pendingFork()!.r }}) will open a new parallel branch lane.
        </span>
        <div class="fork-actions">
          <button type="button" class="confirm-btn" (click)="confirmFork()">Fork New Lane</button>
          <button type="button" class="cancel-btn" (click)="cancelFork()">Cancel</button>
        </div>
      </div>

      <!-- Right-Opening Parallel Branch Tracks -->
      <div class="lanes-scroll">
        <div
          *ngFor="let lane of displayLanes(); let laneIdx = index"
          class="lane-row"
          [class.active-lane]="lane.isLive"
          (click)="selectLane(lane)"
        >
          <!-- Left Lane Metadata -->
          <div class="lane-meta" [style.padding-left.px]="laneIdx === 0 ? 10 : 24">
            <span *ngIf="laneIdx > 0" class="bifurcate-elbow">↳</span>
            <span class="actor-icon" [title]="lane.actor === 'agent' ? 'Agent-initiated lane' : 'Human-initiated lane'">
              {{ lane.actor === 'agent' ? '🤖' : '👤' }}
            </span>
            <span class="lane-name">{{ lane.name }}</span>
            <span *ngIf="lane.reasonBadge" class="fork-badge">[{{ lane.reasonBadge }}]</span>
            <span *ngIf="lane.isLive" class="head-tag">HEAD</span>
          </div>

          <!-- Horizontal Right-Opening Timeline Track -->
          <div class="lane-track">
            <div class="track-line"></div>
            <div class="nodes-strip">
              <button
                *ngFor="let node of lane.nodes"
                type="button"
                class="cp-node"
                [class.selected]="selectedGhost()?.id === node.id"
                [class.has-mutation]="!!node.badge"
                (click)="inspectNode($event, node)"
                [title]="node.label + ' • PC 0x' + toHex(node.pcCpu0) + ' (' + node.timestamp + ')'"
              >
                <span class="node-dot"></span>
                <span class="node-text">{{ node.label }}</span>
                <span *ngIf="node.badge" class="node-badge">{{ node.badge }}</span>
              </button>

              <span *ngIf="lane.nodes.length === 0" class="range-caption">
                r={{ lane.forkR }} → {{ lane.endR }}
              </span>
            </div>
          </div>
        </div>
      </div>

      <!-- Non-Modal Ghost / State Delta Preview Strip -->
      <div *ngIf="selectedGhost()" class="ghost-preview">
        <div class="ghost-head">
          <div class="ghost-title">
            <span class="ghost-tag">Ghost Comparison vs Live HEAD</span>
            <strong>{{ selectedGhost()!.label }}</strong>
            <code>CPU0 PC 0x{{ toHex(selectedGhost()!.pcCpu0) }}</code>
            <span class="actor-caption">({{ selectedGhost()!.actor === 'agent' ? '🤖 Agent' : '👤 Human' }} &#64; {{ selectedGhost()!.timestamp }})</span>
          </div>
          <div class="ghost-hint">
            Tip: Poke any register or memory byte while inspecting this checkpoint to fork a new execution lane from here.
            <button type="button" class="clear-ghost-btn" (click)="clearGhost()">Clear Ghost</button>
          </div>
        </div>

        <div class="ghost-deltas">
          <span *ngIf="ghostRegDeltas().length === 0" class="no-deltas">
            Architectural registers match live HEAD.
          </span>
          <div *ngFor="let d of ghostRegDeltas()" class="delta-chip">
            <span class="d-reg">{{ d.reg.toUpperCase() }}</span>
            <span class="d-old">0x{{ toHex(d.thenVal) }}</span>
            <span class="d-arrow">→</span>
            <span class="d-new">0x{{ toHex(d.nowVal) }}</span>
          </div>
        </div>
      </div>
    </section>
  `,
  styles: [`
    .dag-drawer {
      background: linear-gradient(180deg, rgba(12, 19, 34, 0.96), rgba(6, 10, 19, 0.98));
      border: 1px solid rgba(56, 189, 248, 0.25);
      box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.08), 0 10px 28px rgba(0, 0, 0, 0.45);
      border-radius: 10px;
      overflow: hidden;
      display: flex;
      flex-direction: column;
    }

    .dag-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 8px 12px;
      background: rgba(15, 23, 42, 0.72);
      border-bottom: 1px solid rgba(255, 255, 255, 0.08);
      flex-wrap: wrap;
      gap: 10px;
    }

    .dag-title-wrap {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
    }

    .dag-title {
      font-size: 0.82rem;
      font-weight: 700;
      color: #f8fafc;
    }

    .dag-mode-pill {
      font-size: 0.66rem;
      padding: 2px 8px;
      border-radius: 999px;
      background: rgba(30, 41, 59, 0.8);
      color: #94a3b8;
      border: 1px solid rgba(255, 255, 255, 0.09);
    }
    .dag-mode-pill.disk {
      color: #34d399;
      background: rgba(16, 185, 129, 0.14);
      border-color: rgba(52, 211, 153, 0.35);
    }

    .frame-stats {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.65rem;
      color: #38bdf8;
    }

    .dag-controls {
      display: flex;
      align-items: center;
      gap: 6px;
      flex-wrap: wrap;
    }

    .dag-btn {
      background: rgba(30, 41, 59, 0.85);
      color: #cbd5e1;
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 5px;
      padding: 3px 9px;
      font-size: 0.69rem;
      font-weight: 600;
      cursor: pointer;
    }
    .dag-btn:hover:not(:disabled) { background: #334155; color: #fff; }
    .dag-btn:disabled { opacity: 0.4; cursor: not-allowed; }

    .seek-group {
      display: inline-flex;
      background: #090d16;
      border: 1px solid rgba(255, 255, 255, 0.12);
      border-radius: 5px;
      overflow: hidden;
    }

    .seek-input {
      background: transparent;
      border: none;
      color: #f1f5f9;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.69rem;
      padding: 3px 8px;
      width: 135px;
      outline: none;
    }

    .seek-btn {
      background: #0284c7;
      border: none;
      color: #fff;
      font-size: 0.69rem;
      font-weight: 600;
      padding: 3px 9px;
      cursor: pointer;
    }
    .seek-btn:disabled { opacity: 0.4; cursor: not-allowed; }

    .close-btn {
      background: transparent;
      border: none;
      color: #94a3b8;
      font-size: 0.82rem;
      padding: 2px 6px;
      cursor: pointer;
    }
    .close-btn:hover { color: #fff; }

    .fork-confirm-bar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 6px 12px;
      background: rgba(245, 158, 11, 0.14);
      border-bottom: 1px solid rgba(245, 158, 11, 0.35);
      font-size: 0.72rem;
      color: #fde68a;
      gap: 10px;
      flex-wrap: wrap;
    }

    .fork-actions {
      display: flex;
      gap: 6px;
    }

    .confirm-btn {
      background: #d97706;
      color: #fff;
      border: none;
      border-radius: 4px;
      padding: 3px 10px;
      font-size: 0.69rem;
      font-weight: 600;
      cursor: pointer;
    }
    .cancel-btn {
      background: #334155;
      color: #e2e8f0;
      border: none;
      border-radius: 4px;
      padding: 3px 10px;
      font-size: 0.69rem;
      cursor: pointer;
    }

    .lanes-scroll {
      max-height: 175px;
      overflow-y: auto;
      display: flex;
      flex-direction: column;
    }

    .lane-row {
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 7px 12px;
      border-bottom: 1px solid rgba(255, 255, 255, 0.05);
      cursor: pointer;
    }
    .lane-row:hover { background: rgba(30, 41, 59, 0.35); }
    .lane-row.active-lane {
      background: rgba(2, 132, 199, 0.09);
      box-shadow: inset 3px 0 0 #38bdf8;
    }

    .lane-meta {
      display: flex;
      align-items: center;
      gap: 6px;
      min-width: 230px;
      font-size: 0.72rem;
    }

    .bifurcate-elbow {
      color: #38bdf8;
      font-family: "JetBrains Mono", monospace;
      font-weight: 700;
    }

    .lane-name {
      font-weight: 600;
      color: #e2e8f0;
      white-space: nowrap;
    }

    .fork-badge {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.64rem;
      color: #fbbf24;
      background: rgba(245, 158, 11, 0.15);
      padding: 0 4px;
      border-radius: 3px;
    }

    .head-tag {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.6rem;
      font-weight: 700;
      color: #38bdf8;
      background: rgba(56, 189, 248, 0.16);
      border: 1px solid rgba(56, 189, 248, 0.35);
      padding: 0 5px;
      border-radius: 4px;
    }

    .lane-track {
      position: relative;
      flex: 1;
      overflow-x: auto;
      padding: 3px 0;
    }

    .track-line {
      position: absolute;
      left: 0;
      right: 0;
      top: 50%;
      height: 2px;
      background: linear-gradient(90deg, rgba(56, 189, 248, 0.45), rgba(148, 163, 184, 0.18));
      transform: translateY(-50%);
      pointer-events: none;
    }

    .nodes-strip {
      position: relative;
      display: inline-flex;
      align-items: center;
      gap: 8px;
      z-index: 1;
    }

    .cp-node {
      display: inline-flex;
      align-items: center;
      gap: 5px;
      padding: 3px 8px;
      border-radius: 999px;
      background: #0f172a;
      border: 1px solid rgba(148, 163, 184, 0.28);
      color: #cbd5e1;
      font-size: 0.67rem;
      cursor: pointer;
      white-space: nowrap;
      transition: all 0.12s;
    }
    .cp-node:hover {
      border-color: #38bdf8;
      color: #fff;
    }
    .cp-node.has-mutation {
      border-color: rgba(245, 158, 11, 0.5);
    }
    .cp-node.selected {
      background: rgba(245, 158, 11, 0.22);
      border-color: #fbbf24;
      color: #fef3c7;
    }

    .node-dot {
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: #38bdf8;
    }
    .cp-node.has-mutation .node-dot {
      background: #fbbf24;
    }

    .node-badge {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.6rem;
      font-weight: 700;
      color: #fbbf24;
    }

    .range-caption {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.66rem;
      color: #64748b;
      background: #090d16;
      padding: 2px 7px;
      border-radius: 4px;
    }

    .ghost-preview {
      padding: 8px 12px;
      background: rgba(15, 23, 42, 0.88);
      border-top: 1px solid rgba(245, 158, 11, 0.28);
      display: flex;
      flex-direction: column;
      gap: 6px;
    }

    .ghost-head {
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-wrap: wrap;
      gap: 8px;
      font-size: 0.71rem;
    }

    .ghost-title {
      display: flex;
      align-items: center;
      gap: 8px;
      color: #f1f5f9;
      flex-wrap: wrap;
    }
    .ghost-title code {
      font-family: "JetBrains Mono", monospace;
      color: #38bdf8;
      font-size: 0.68rem;
    }

    .ghost-tag {
      font-size: 0.64rem;
      font-weight: 700;
      color: #fbbf24;
      background: rgba(245, 158, 11, 0.16);
      padding: 1px 6px;
      border-radius: 4px;
    }

    .actor-caption,
    .ghost-hint {
      font-size: 0.67rem;
      color: #94a3b8;
    }

    .clear-ghost-btn {
      margin-left: 8px;
      background: rgba(51, 65, 85, 0.8);
      border: none;
      color: #e2e8f0;
      font-size: 0.66rem;
      padding: 2px 7px;
      border-radius: 4px;
      cursor: pointer;
    }

    .ghost-deltas {
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
    }

    .no-deltas {
      font-size: 0.69rem;
      color: #64748b;
    }

    .delta-chip {
      display: inline-flex;
      align-items: center;
      gap: 5px;
      padding: 2px 7px;
      border-radius: 4px;
      background: rgba(9, 13, 22, 0.85);
      border: 1px solid rgba(245, 158, 11, 0.35);
      font-family: "JetBrains Mono", monospace;
      font-size: 0.67rem;
    }
    .d-reg { color: #94a3b8; font-weight: 700; }
    .d-old { color: #64748b; }
    .d-arrow { color: #fbbf24; }
    .d-new { color: #fbbf24; font-weight: 700; }
  `]
})
export class ExecutionDagComponent {
  public emu = inject(EmulatorService);
  public seekTarget = signal<string>('');

  public isConnected = computed(() => this.emu.connectionState() === 'connected');
  public selectedGhost = this.emu.selectedGhostNode;

  public pendingFork = computed(() => {
    const fs = this.emu.forkStatus();
    return fs && fs.pending ? fs : null;
  });

  public frameStatsText = computed(() => {
    const fs = this.emu.frameStatus();
    if (!fs) return '';
    const ramMb = (Number(fs.ramBytes) / (1024 * 1024)).toFixed(1);
    return `${fs.frames} frames • ${ramMb} MiB history`;
  });

  public displayLanes = computed<DagLaneView[]>(() => {
    const backend = this.emu.backendBranches();
    const session = this.emu.sessionLanes();
    if (backend.length === 0) return session;

    return backend.map((b) => {
      const matchingSession = session.find((s) => s.id === b.id);
      return {
        id: b.id,
        parent: b.parent,
        name: b.id === 0 || b.parent === 0 ? `Branch #${b.id} (Root)` : `Branch #${b.id} (from #${b.parent})`,
        forkR: b.forkR,
        endR: b.recordedEndR,
        reason: b.reason,
        reasonBadge: forkReasonBadge(b.reason),
        actor: matchingSession?.actor ?? 'human',
        isLive: b.isLive,
        isPinned: b.isPinned,
        nodes: matchingSession?.nodes ?? [],
      };
    });
  });

  public ghostRegDeltas = computed(() => {
    const ghost = this.selectedGhost();
    if (!ghost) return [];
    const curr = this.emu.cpu0Registers();
    const out: Array<{ reg: string; thenVal: number; nowVal: number }> = [];
    for (const [reg, thenVal] of Object.entries(ghost.registersCpu0)) {
      const nowVal = curr[reg] ?? 0;
      if (thenVal !== nowVal) {
        out.push({ reg, thenVal, nowVal });
      }
    }
    return out;
  });

  public badgeOf = forkReasonBadge;

  public selectLane(lane: DagLaneView): void {
    void this.emu.switchBranch(lane.id);
  }

  public inspectNode(event: MouseEvent, node: DagCheckpointNode): void {
    event.stopPropagation();
    this.emu.selectGhostCheckpoint(node);
  }

  public clearGhost(): void {
    this.emu.selectGhostCheckpoint(null);
  }

  public runSeek(): void {
    if (!this.seekTarget().trim()) return;
    void this.emu.seekTo(this.seekTarget());
  }

  public playBack(): void {
    void this.emu.playHistory(Direction.Back, 1000n);
  }

  public playForward(): void {
    void this.emu.playHistory(Direction.Fwd, 1000n);
  }

  public confirmFork(): void {
    void this.emu.confirmPendingFork();
  }

  public cancelFork(): void {
    void this.emu.cancelPendingFork();
  }

  public close(): void {
    this.emu.dagDrawerOpen.set(false);
  }

  public toHex(val: number): string {
    return (val >>> 0).toString(16).padStart(8, '0');
  }
}
