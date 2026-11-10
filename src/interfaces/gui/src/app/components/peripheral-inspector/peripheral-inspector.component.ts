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
    <div class="pane-card">
      <div class="pane-header">
        <span class="pane-title">Peripherals &amp; Bus Fabric</span>
        <div class="tab-strip">
          <button
            type="button"
            class="tab-btn"
            [class.active]="tab() === 'mmio'"
            (click)="tab.set('mmio')"
          >
            MMIO ({{ emu.periphBlocks().length }})
          </button>
          <button
            type="button"
            class="tab-btn"
            [class.active]="tab() === 'parts'"
            (click)="tab.set('parts')"
          >
            Parts ({{ emu.fittedParts().length }})
          </button>
          <button
            type="button"
            class="tab-btn"
            [class.active]="tab() === 'activity'"
            (click)="tab.set('activity')"
          >
            Events ({{ emu.activityLog().length }})
          </button>
        </div>
      </div>

      <!-- Tab 1: Modelled On-Chip Peripheral MMIO Blocks -->
      <div *ngIf="tab() === 'mmio'" class="tab-body">
        <div class="mmio-toolbar">
          <input
            type="text"
            class="filter-input"
            placeholder="Filter block (GPIO, SCI8, GLCDC, GPT...)"
            [ngModel]="filterText()"
            (ngModelChange)="filterText.set($event)"
          />
          <select
            class="block-select"
            [ngModel]="emu.selectedPeriphBlock()"
            (ngModelChange)="onSelectBlock($event)"
            [disabled]="filteredBlocks().length === 0"
          >
            <option *ngFor="let b of filteredBlocks()" [value]="b">{{ b }}</option>
          </select>
          <button
            type="button"
            class="icon-btn"
            [disabled]="!isConnected()"
            (click)="refreshSelectedBlock()"
            title="Refresh block registers"
          >
            ↻
          </button>
        </div>

        <pre class="mmio-dump">{{ emu.selectedPeriphText() || 'Connect emulator backend to inspect modelled RA8 peripheral registers.' }}</pre>
      </div>

      <!-- Tab 2: Fitted Off-Chip Components (I2C/SPI/MIPI/OSPI) -->
      <div *ngIf="tab() === 'parts'" class="tab-body">
        <div *ngIf="emu.fittedParts().length === 0" class="empty-note">
          {{ isConnected() ? 'No pluggable off-chip parts attached on external buses.' : 'Connect backend to query fitted I2C/SPI/MIPI parts.' }}
        </div>
        <div class="parts-list" *ngIf="emu.fittedParts().length > 0">
          <div *ngFor="let p of emu.fittedParts()" class="part-row">
            <span class="part-dot"></span>
            <code>{{ p }}</code>
          </div>
        </div>
      </div>

      <!-- Tab 3: Bus, Fault, ISR, & Session Activity Log -->
      <div *ngIf="tab() === 'activity'" class="tab-body">
        <div *ngIf="emu.activityLog().length === 0" class="empty-note">
          No bus, fault, or session events recorded yet.
        </div>
        <div class="log-list" *ngIf="emu.activityLog().length > 0">
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
      gap: 8px;
      flex-wrap: wrap;
    }

    .pane-title {
      font-size: 0.8rem;
      font-weight: 600;
      color: #f1f5f9;
    }

    .tab-strip {
      display: inline-flex;
      background: #090d16;
      border: 1px solid rgba(255, 255, 255, 0.09);
      border-radius: 5px;
      overflow: hidden;
    }

    .tab-btn {
      background: transparent;
      border: none;
      color: #94a3b8;
      font-size: 0.66rem;
      font-weight: 600;
      padding: 3px 8px;
      cursor: pointer;
    }
    .tab-btn.active {
      background: rgba(2, 132, 199, 0.28);
      color: #38bdf8;
    }

    .tab-body {
      padding: 8px 10px;
      display: flex;
      flex-direction: column;
      gap: 6px;
    }

    .mmio-toolbar {
      display: flex;
      gap: 6px;
      align-items: center;
    }

    .filter-input,
    .block-select {
      background: #090d16;
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 5px;
      color: #e2e8f0;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.69rem;
      padding: 3px 7px;
      outline: none;
    }
    .filter-input { flex: 1; min-width: 90px; }
    .block-select { max-width: 120px; }

    .icon-btn {
      background: rgba(30, 41, 59, 0.8);
      border: 1px solid rgba(255, 255, 255, 0.1);
      color: #cbd5e1;
      border-radius: 5px;
      padding: 2px 7px;
      cursor: pointer;
    }
    .icon-btn:disabled { opacity: 0.35; cursor: not-allowed; }

    .mmio-dump {
      max-height: 155px;
      overflow: auto;
      background: rgba(6, 9, 15, 0.85);
      border: 1px solid rgba(255, 255, 255, 0.06);
      border-radius: 6px;
      padding: 6px 8px;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.67rem;
      line-height: 1.4;
      color: #cbd5e1;
      white-space: pre;
    }

    .empty-note {
      padding: 14px 6px;
      text-align: center;
      font-size: 0.7rem;
      color: #64748b;
    }

    .parts-list,
    .log-list {
      max-height: 165px;
      overflow-y: auto;
      display: flex;
      flex-direction: column;
      gap: 4px;
    }

    .part-row,
    .log-row {
      display: flex;
      align-items: center;
      gap: 7px;
      padding: 4px 7px;
      background: rgba(9, 13, 22, 0.7);
      border: 1px solid rgba(255, 255, 255, 0.05);
      border-radius: 5px;
      font-size: 0.68rem;
    }
    .log-row.fault {
      border-color: rgba(239, 68, 68, 0.4);
      background: rgba(127, 29, 29, 0.18);
    }

    .part-dot {
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: #34d399;
    }
    .part-row code,
    .log-detail {
      font-family: "JetBrains Mono", monospace;
      color: #38bdf8;
      font-size: 0.66rem;
    }

    .log-time {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.62rem;
      color: #64748b;
    }
    .log-core {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.62rem;
      font-weight: 700;
      color: #a855f7;
    }
    .log-label {
      color: #e2e8f0;
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
