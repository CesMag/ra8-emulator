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
    <div class="dag-pane">
      <!-- Sub-Toolbar -->
      <div class="dag-subtoolbar">
        <div class="sub-left">
          <span class="dag-mode-pill" [class.disk]="emu.historySupported()">
            {{ emu.historySupported() ? 'Persistent Rewind Active' : 'Live Session DAG' }}
          </span>
          <span *ngIf="frameStatsText()" class="frame-stats font-mono">{{ frameStatsText() }}</span>
        </div>

        <div class="sub-right">
          <button
            type="button"
            class="dag-btn"
            [disabled]="!isConnected()"
            (click)="playBack()"
            title="Play Recorded History Backward"
          >
            ⏪ Rev Play
          </button>
          <button
            type="button"
            class="dag-btn"
            [disabled]="!isConnected()"
            (click)="playForward()"
            title="Play Recorded History Forward"
          >
            ⏩ Fwd Replay
          </button>

          <div class="seek-group font-mono">
            <input
              type="text"
              class="seek-input font-mono"
              placeholder="Seek: 0, 50ms, #4..."
              [ngModel]="seekTarget()"
              (ngModelChange)="seekTarget.set($event)"
              (keydown.enter)="runSeek()"
            />
            <button type="button" class="seek-btn" [disabled]="!isConnected()" (click)="runSeek()">
              Seek
            </button>
          </div>
        </div>
      </div>

      <!-- Pending Hardware Fork Bar -->
      <div *ngIf="pendingFork()" class="fork-confirm-bar font-mono">
        <span>
          <strong>Timeline Bifurcation:</strong>
          Mutation [{{ badgeOf(pendingFork()!.reason) || 'W' }}] at branch #{{ pendingFork()!.branch }} will fork a new lane.
        </span>
        <div class="fork-actions">
          <button type="button" class="confirm-btn" (click)="confirmFork()">Fork Lane</button>
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
          <div class="lane-meta" [style.padding-left.px]="laneIdx === 0 ? 8 : 20">
            <span *ngIf="laneIdx > 0" class="bifurcate-elbow font-mono">↳</span>
            <span class="actor-icon" [title]="lane.actor === 'agent' ? 'Agent lane' : 'Human lane'">
              {{ lane.actor === 'agent' ? '🤖' : '👤' }}
            </span>
            <span class="lane-name">{{ lane.name }}</span>
            <span *ngIf="lane.reasonBadge" class="fork-badge font-mono">[{{ lane.reasonBadge }}]</span>
            <span *ngIf="lane.isLive" class="head-tag font-mono">HEAD</span>
          </div>

          <!-- Horizontal Timeline Track -->
          <div class="lane-track">
            <div class="track-line"></div>
            <div class="nodes-strip">
              <button
                *ngFor="let node of lane.nodes"
                type="button"
                class="cp-node font-mono"
                [class.selected]="selectedGhost()?.id === node.id"
                [class.has-mutation]="!!node.badge"
                (click)="inspectNode($event, node)"
                [title]="node.label + ' • PC 0x' + toHex(node.pcCpu0) + ' (' + node.timestamp + ')'"
              >
                <span class="node-dot"></span>
                <span class="node-text">{{ node.label }}</span>
                <span *ngIf="node.badge" class="node-badge">{{ node.badge }}</span>
              </button>

              <span *ngIf="lane.nodes.length === 0" class="range-caption font-mono">
                r={{ lane.forkR }} → {{ lane.endR }}
              </span>
            </div>
          </div>
        </div>
      </div>

      <!-- Non-Modal Ghost Preview Strip -->
      <div *ngIf="selectedGhost()" class="ghost-preview">
        <div class="ghost-head">
          <div class="ghost-title">
            <span class="ghost-tag font-mono">Ghost vs Live HEAD</span>
            <strong>{{ selectedGhost()!.label }}</strong>
            <code class="font-mono">CPU0 PC 0x{{ toHex(selectedGhost()!.pcCpu0) }}</code>
            <span class="actor-caption font-mono">({{ selectedGhost()!.actor === 'agent' ? '🤖 Agent' : '👤 Human' }})</span>
          </div>
          <button type="button" class="clear-ghost-btn" (click)="clearGhost()">Clear</button>
        </div>

        <div class="ghost-deltas font-mono">
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
    </div>
  `,
  styles: [`
    .dag-pane {
      height: 100%;
      display: flex;
      flex-direction: column;
      overflow: hidden;
      background: var(--bg-surface);
    }

    .dag-subtoolbar {
      height: 28px;
      min-height: 28px;
      background: var(--bg-surface);
      border-bottom: 1px solid var(--border-subtle);
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 10px;
      flex-shrink: 0;
      gap: 8px;
    }

    .sub-left, .sub-right {
      display: flex;
      align-items: center;
      gap: 6px;
    }

    .dag-mode-pill {
      font-size: 10px;
      padding: 1px 6px;
      border-radius: var(--radius-sm);
      background: var(--bg-well);
      color: var(--text-secondary);
    }
    .dag-mode-pill.disk {
      color: var(--accent-green);
      background: var(--accent-green-subtle);
    }

    .frame-stats {
      font-size: 10px;
      color: var(--text-tertiary);
    }

    .dag-btn {
      background: transparent;
      border: 1px solid var(--border-subtle);
      color: var(--text-secondary);
      border-radius: var(--radius-sm);
      padding: 2px 7px;
      font-size: 10px;
      font-weight: 500;
      cursor: pointer;
    }
    .dag-btn:hover:not(:disabled) {
      background: var(--bg-well);
      color: var(--text-primary);
    }
    .dag-btn:disabled { opacity: 0.35; cursor: not-allowed; }

    .seek-group {
      display: inline-flex;
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      overflow: hidden;
    }

    .seek-input {
      background: transparent;
      border: none;
      color: var(--text-primary);
      font-size: 10px;
      padding: 2px 6px;
      width: 100px;
      outline: none;
    }

    .seek-btn {
      background: var(--accent-blue);
      border: none;
      color: #ffffff;
      font-size: 10px;
      font-weight: 600;
      padding: 2px 7px;
      cursor: pointer;
    }
    .seek-btn:disabled { opacity: 0.35; cursor: not-allowed; }

    .fork-confirm-bar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 4px 10px;
      background: var(--accent-amber-subtle);
      border-bottom: 1px solid var(--accent-amber);
      font-size: 10px;
      color: var(--text-primary);
      flex-shrink: 0;
    }

    .fork-actions {
      display: flex;
      gap: 4px;
    }

    .confirm-btn {
      background: var(--accent-amber);
      color: #000000;
      border: none;
      border-radius: var(--radius-sm);
      padding: 2px 6px;
      font-size: 10px;
      font-weight: 600;
      cursor: pointer;
    }

    .cancel-btn {
      background: var(--border-subtle);
      color: var(--text-secondary);
      border: none;
      border-radius: var(--radius-sm);
      padding: 2px 6px;
      font-size: 10px;
      cursor: pointer;
    }

    .lanes-scroll {
      flex: 1;
      min-height: 0;
      overflow-y: auto;
      display: flex;
      flex-direction: column;
    }

    .lane-row {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 4px 10px;
      border-bottom: 1px solid var(--border-subtle);
      cursor: pointer;
      min-height: 28px;
    }
    .lane-row:hover { background: var(--bg-well); }
    .lane-row.active-lane {
      background: var(--accent-blue-subtle);
      box-shadow: inset 2px 0 0 var(--accent-blue);
    }

    .lane-meta {
      display: flex;
      align-items: center;
      gap: 6px;
      min-width: 190px;
      font-size: 11px;
    }

    .bifurcate-elbow {
      color: var(--accent-blue);
      font-weight: 700;
    }

    .lane-name {
      font-weight: 500;
      color: var(--text-primary);
      white-space: nowrap;
    }

    .fork-badge {
      font-size: 9px;
      color: var(--accent-amber);
      background: var(--accent-amber-subtle);
      padding: 0 4px;
      border-radius: 2px;
    }

    .head-tag {
      font-size: 9px;
      font-weight: 700;
      color: var(--accent-blue);
      background: var(--accent-blue-subtle);
      padding: 0 4px;
      border-radius: 2px;
    }

    .lane-track {
      position: relative;
      flex: 1;
      overflow-x: auto;
      padding: 2px 0;
    }

    .track-line {
      position: absolute;
      left: 0;
      right: 0;
      top: 50%;
      height: 1px;
      background: var(--border-subtle);
      transform: translateY(-50%);
      pointer-events: none;
    }

    .nodes-strip {
      position: relative;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      z-index: 1;
    }

    .cp-node {
      display: inline-flex;
      align-items: center;
      gap: 4px;
      padding: 2px 6px;
      border-radius: var(--radius-sm);
      background: var(--bg-surface);
      border: 1px solid var(--border-subtle);
      color: var(--text-secondary);
      font-size: 10px;
      cursor: pointer;
      white-space: nowrap;
      transition: all 0.12s;
    }
    .cp-node:hover {
      border-color: var(--accent-blue);
      color: var(--text-primary);
    }
    .cp-node.selected {
      background: var(--accent-amber-subtle);
      border-color: var(--accent-amber);
      color: var(--accent-amber);
    }

    .node-dot {
      width: 5px;
      height: 5px;
      border-radius: 50%;
      background: var(--accent-blue);
    }
    .cp-node.has-mutation .node-dot {
      background: var(--accent-amber);
    }

    .node-badge {
      font-size: 9px;
      font-weight: 700;
      color: var(--accent-amber);
    }

    .range-caption {
      font-size: 10px;
      color: var(--text-tertiary);
    }

    .ghost-preview {
      padding: 6px 10px;
      background: var(--bg-well);
      border-top: 1px solid var(--border-subtle);
      display: flex;
      flex-direction: column;
      gap: 4px;
      flex-shrink: 0;
    }

    .ghost-head {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 10px;
    }

    .ghost-title {
      display: flex;
      align-items: center;
      gap: 6px;
      color: var(--text-primary);
    }
    .ghost-title code {
      color: var(--accent-blue);
    }

    .ghost-tag {
      font-size: 9px;
      font-weight: 700;
      color: var(--accent-amber);
      background: var(--accent-amber-subtle);
      padding: 1px 4px;
      border-radius: 2px;
    }

    .actor-caption {
      color: var(--text-tertiary);
    }

    .clear-ghost-btn {
      background: var(--border-subtle);
      border: none;
      color: var(--text-secondary);
      font-size: 10px;
      padding: 1px 6px;
      border-radius: var(--radius-sm);
      cursor: pointer;
    }

    .ghost-deltas {
      display: flex;
      flex-wrap: wrap;
      gap: 4px;
    }

    .no-deltas {
      font-size: 10px;
      color: var(--text-tertiary);
    }

    .delta-chip {
      display: inline-flex;
      align-items: center;
      gap: 4px;
      padding: 1px 5px;
      border-radius: 2px;
      background: var(--bg-surface);
      border: 1px solid var(--border-subtle);
      font-size: 10px;
    }
    .d-reg { color: var(--text-secondary); font-weight: 600; }
    .d-old { color: var(--text-tertiary); }
    .d-arrow { color: var(--accent-amber); }
    .d-new { color: var(--accent-amber); font-weight: 600; }
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

  public toHex(val: number): string {
    return (val >>> 0).toString(16).padStart(8, '0');
  }
}
