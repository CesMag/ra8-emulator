import { Component, inject, signal, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { EmulatorService } from '../../services/emulator.service';
import { Core } from 'ra8-rpc-client';

type PeriphTab = 'mmio' | 'parts' | 'activity';

@Component({
  selector: 'app-peripheral-inspector',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="peripheral-pane">
      <!-- Sub-Toolbar -->
      <div class="peripheral-subtoolbar">
        <div class="segmented-control">
          <button
            type="button"
            class="seg-item"
            [class.active]="tab() === 'mmio'"
            (click)="tab.set('mmio')"
          >
            MMIO ({{ emu.periphBlocks().length }})
          </button>
          <button
            type="button"
            class="seg-item"
            [class.active]="tab() === 'parts'"
            (click)="tab.set('parts')"
          >
            Parts ({{ emu.fittedParts().length }})
          </button>
          <button
            type="button"
            class="seg-item"
            [class.active]="tab() === 'activity'"
            (click)="tab.set('activity')"
          >
            Events ({{ emu.activityLog().length }})
          </button>
        </div>
      </div>

      <!-- Tab 1: MMIO Blocks -->
      <div *ngIf="tab() === 'mmio'" class="tab-body">
        <div class="filter-strip">
          <input
            type="text"
            class="filter-input font-mono"
            placeholder="Filter block (GPIO, SCI8, GLCDC...)"
            [ngModel]="filterText()"
            (ngModelChange)="filterText.set($event)"
          />
          <select
            class="block-select font-mono"
            [ngModel]="emu.selectedPeriphBlock()"
            (ngModelChange)="onSelectBlock($event)"
            [disabled]="filteredBlocks().length === 0"
          >
            <option *ngFor="let b of filteredBlocks()" [value]="b">{{ b }}</option>
          </select>
          <button
            type="button"
            class="action-btn"
            [disabled]="!isConnected()"
            (click)="refreshSelectedBlock()"
            title="Refresh registers"
          >
            ↻
          </button>
        </div>

        <pre class="mmio-dump font-mono">{{ emu.selectedPeriphText() || 'Connect emulator backend to inspect modelled peripheral registers.' }}</pre>
      </div>

      <!-- Tab 2: Fitted Parts -->
      <div *ngIf="tab() === 'parts'" class="tab-body">
        <div *ngIf="emu.fittedParts().length === 0" class="empty-note">
          {{ isConnected() ? 'No pluggable off-chip parts attached on external buses.' : 'Connect backend to query fitted parts.' }}
        </div>
        <div class="parts-list" *ngIf="emu.fittedParts().length > 0">
          <div *ngFor="let p of emu.fittedParts()" class="part-row">
            <span class="part-dot"></span>
            <code class="font-mono">{{ p }}</code>
          </div>
        </div>
      </div>

      <!-- Tab 3: Bus Activity Log -->
      <div *ngIf="tab() === 'activity'" class="tab-body">
        <div *ngIf="emu.activityLog().length === 0" class="empty-note">
          No bus, fault, or session events recorded yet.
        </div>
        <div class="log-list font-mono" *ngIf="emu.activityLog().length > 0">
          <div *ngFor="let item of emu.activityLog()" class="log-row" [class.fault]="item.category === 'fault'">
            <span class="log-time">{{ item.time }}</span>
            <span class="log-core">{{ item.core === Core.Cpu0 ? 'M85' : 'M33' }}</span>
            <span class="log-label">{{ item.label }}</span>
            <code class="log-detail">{{ item.detail }}</code>
          </div>
        </div>
      </div>
    </div>
  `,
  styles: [`
    .peripheral-pane {
      height: 100%;
      display: flex;
      flex-direction: column;
      overflow: hidden;
      background: var(--bg-surface);
    }

    .peripheral-subtoolbar {
      height: 28px;
      min-height: 28px;
      background: var(--bg-surface);
      border-bottom: 1px solid var(--border-subtle);
      display: flex;
      align-items: center;
      padding: 0 10px;
      flex-shrink: 0;
    }

    .segmented-control {
      display: inline-flex;
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      padding: 1px;
      gap: 1px;
    }

    .seg-item {
      background: transparent;
      border: none;
      color: var(--text-secondary);
      font-size: 10px;
      font-weight: 500;
      padding: 2px 7px;
      border-radius: 3px;
      cursor: pointer;
      transition: all 0.12s;
    }

    .seg-item:hover {
      color: var(--text-primary);
    }

    .seg-item.active {
      background: var(--bg-surface);
      color: var(--accent-blue);
      font-weight: 600;
      box-shadow: 0 1px 3px rgba(0, 0, 0, 0.12);
    }

    .tab-body {
      flex: 1;
      min-height: 0;
      overflow: hidden;
      display: flex;
      flex-direction: column;
      padding: 6px 8px;
      gap: 6px;
    }

    .filter-strip {
      display: flex;
      gap: 6px;
      align-items: center;
    }

    .filter-input, .block-select {
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      color: var(--text-primary);
      font-size: 10px;
      padding: 3px 6px;
      outline: none;
    }

    .filter-input { flex: 1; }
    .block-select { max-width: 140px; }

    .action-btn {
      background: var(--border-subtle);
      border: none;
      color: var(--text-secondary);
      border-radius: var(--radius-sm);
      padding: 3px 7px;
      font-size: 11px;
      cursor: pointer;
    }
    .action-btn:hover:not(:disabled) {
      color: var(--text-primary);
      background: var(--border-strong);
    }
    .action-btn:disabled {
      opacity: 0.35;
      cursor: not-allowed;
    }

    .mmio-dump {
      flex: 1;
      min-height: 0;
      overflow: auto;
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      padding: 6px 8px;
      font-size: 11px;
      line-height: 1.4;
      color: var(--text-primary);
      white-space: pre;
    }

    .empty-note {
      padding: 24px 10px;
      text-align: center;
      font-size: 11px;
      color: var(--text-tertiary);
    }

    .parts-list, .log-list {
      flex: 1;
      min-height: 0;
      overflow-y: auto;
      display: flex;
      flex-direction: column;
      gap: 3px;
    }

    .part-row, .log-row {
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 3px 7px;
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      font-size: 11px;
    }

    .log-row.fault {
      border-color: var(--accent-red);
      background: var(--accent-red-subtle);
    }

    .part-dot {
      width: 5px;
      height: 5px;
      border-radius: 50%;
      background: var(--accent-green);
    }

    .part-row code, .log-detail {
      color: var(--accent-blue);
      font-size: 10px;
    }

    .log-time {
      font-size: 9px;
      color: var(--text-tertiary);
    }

    .log-core {
      font-size: 10px;
      font-weight: 700;
      color: var(--accent-purple);
    }

    .log-label {
      color: var(--text-primary);
      flex: 1;
    }
  `]
})
export class PeripheralInspectorComponent {
  public emu = inject(EmulatorService);
  public Core = Core;

  public tab = signal<PeriphTab>('mmio');
  public filterText = signal<string>('');
  public isConnected = computed(() => this.emu.connectionState() === 'connected');

  public filteredBlocks = computed(() => {
    const q = this.filterText().trim().toLowerCase();
    const all = this.emu.periphBlocks();
    if (!q) return all;
    return all.filter((b) => b.toLowerCase().includes(q));
  });

  public onSelectBlock(block: string): void {
    void this.emu.selectPeriphBlock(block);
  }

  public refreshSelectedBlock(): void {
    const b = this.emu.selectedPeriphBlock();
    if (b) {
      void this.emu.selectPeriphBlock(b);
    } else {
      void this.emu.refreshPeripheralsList();
    }
  }
}
