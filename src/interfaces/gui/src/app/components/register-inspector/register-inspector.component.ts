import { Component, inject, computed, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { EmulatorService } from '../../services/emulator.service';
import { Core, Register } from 'ra8-rpc-client';

interface RegisterEntry {
  key: string;
  core: Core;
  name: string;
  reg: Register;
  value: number;
  hex: string;
  changed: boolean;
}

const REG_SPECS: Array<{ name: string; reg: Register }> = [
  { name: 'pc', reg: Register.Pc },
  { name: 'sp', reg: Register.Sp },
  { name: 'lr', reg: Register.Lr },
  { name: 'xpsr', reg: Register.Xpsr },
  { name: 'msp', reg: Register.Msp },
  { name: 'psp', reg: Register.Psp },
  { name: 'r0', reg: Register.R0 },
  { name: 'r1', reg: Register.R1 },
  { name: 'r2', reg: Register.R2 },
  { name: 'r3', reg: Register.R3 },
  { name: 'r4', reg: Register.R4 },
  { name: 'r5', reg: Register.R5 },
  { name: 'r6', reg: Register.R6 },
  { name: 'r7', reg: Register.R7 },
  { name: 'r8', reg: Register.R8 },
  { name: 'r9', reg: Register.R9 },
  { name: 'r10', reg: Register.R10 },
  { name: 'r11', reg: Register.R11 },
  { name: 'r12', reg: Register.R12 },
];

@Component({
  selector: 'app-register-inspector',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="pane-card">
      <div class="pane-header">
        <div class="header-left">
          <span class="pane-title">Architectural Registers</span>
          <span *ngIf="deltaCount() > 0" class="delta-badge">Δ {{ deltaCount() }} modified</span>
        </div>
        <button
          type="button"
          class="refresh-btn"
          (click)="refresh()"
          [disabled]="!isConnected()"
          title="Refresh Dual-Core Registers"
        >
          ↻
        </button>
      </div>

      <div class="cores-wrap" [class.split]="showSplit()">
        <!-- CPU0 (Cortex-M85) -->
        <div *ngIf="showCpu0()" class="core-col">
          <div class="core-bar m85">CPU0 • Cortex-M85</div>
          <div class="reg-grid">
            <div
              *ngFor="let item of cpu0Entries()"
              class="reg-cell"
              [class.changed]="item.changed"
            >
              <span class="reg-name">{{ item.name.toUpperCase() }}</span>
              <span
                *ngIf="editingKey() !== item.key"
                class="reg-val"
                [class.changed]="item.changed"
                (click)="startEdit(item)"
                title="Click to poke register"
              >
                0x{{ item.hex }}
              </span>
              <input
                *ngIf="editingKey() === item.key"
                type="text"
                class="reg-input"
                [ngModel]="editValue()"
                (ngModelChange)="editValue.set($event)"
                (keydown.enter)="saveEdit(item)"
                (keydown.escape)="cancelEdit()"
                (blur)="cancelEdit()"
                autofocus
              />
            </div>
          </div>
        </div>

        <!-- CPU1 (Cortex-M33) -->
        <div *ngIf="showCpu1()" class="core-col">
          <div class="core-bar m33">CPU1 • Cortex-M33</div>
          <div *ngIf="!emu.cpu1Attached()" class="gated-note">
            CPU1 clock-gated (awaiting dual-core image)
          </div>
          <div *ngIf="emu.cpu1Attached()" class="reg-grid">
            <div
              *ngFor="let item of cpu1Entries()"
              class="reg-cell"
              [class.changed]="item.changed"
            >
              <span class="reg-name">{{ item.name.toUpperCase() }}</span>
              <span
                *ngIf="editingKey() !== item.key"
                class="reg-val"
                [class.changed]="item.changed"
                (click)="startEdit(item)"
                title="Click to poke register"
              >
                0x{{ item.hex }}
              </span>
              <input
                *ngIf="editingKey() === item.key"
                type="text"
                class="reg-input"
                [ngModel]="editValue()"
                (ngModelChange)="editValue.set($event)"
                (keydown.enter)="saveEdit(item)"
                (keydown.escape)="cancelEdit()"
                (blur)="cancelEdit()"
                autofocus
              />
            </div>
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

    .header-left {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .pane-title {
      font-size: 0.8rem;
      font-weight: 600;
      color: #f1f5f9;
    }

    .delta-badge {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.64rem;
      color: #fbbf24;
      background: rgba(245, 158, 11, 0.14);
      border: 1px solid rgba(245, 158, 11, 0.35);
      padding: 1px 6px;
      border-radius: 999px;
    }

    .refresh-btn {
      background: transparent;
      border: none;
      color: #94a3b8;
      font-size: 0.88rem;
      cursor: pointer;
    }
    .refresh-btn:disabled { opacity: 0.35; cursor: not-allowed; }

    .cores-wrap {
      display: grid;
      grid-template-columns: 1fr;
      max-height: 360px;
      overflow-y: auto;
    }
    .cores-wrap.split {
      grid-template-columns: 1fr;
    }

    .core-col + .core-col {
      border-top: 1px solid rgba(255, 255, 255, 0.07);
    }

    .core-bar {
      padding: 4px 10px;
      font-size: 0.67rem;
      font-weight: 600;
      background: rgba(9, 13, 22, 0.72);
      border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    }
    .core-bar.m85 { color: #38bdf8; }
    .core-bar.m33 { color: #c084fc; }

    .gated-note {
      padding: 10px 12px;
      font-size: 0.7rem;
      color: #64748b;
    }

    .reg-grid {
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 4px 6px;
      padding: 7px 8px;
    }

    .reg-cell {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 2px 6px;
      background: rgba(9, 13, 22, 0.65);
      border: 1px solid rgba(255, 255, 255, 0.06);
      border-radius: 5px;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.71rem;
      transition: border-color 0.2s, background 0.2s;
    }

    .reg-cell.changed {
      border-color: rgba(245, 158, 11, 0.45);
      background: rgba(245, 158, 11, 0.1);
      box-shadow: 0 0 8px rgba(245, 158, 11, 0.12);
    }

    .reg-name {
      color: #94a3b8;
      font-weight: 600;
      font-size: 0.67rem;
    }

    .reg-val {
      color: #e2e8f0;
      cursor: pointer;
      padding: 0 3px;
      border-radius: 3px;
    }
    .reg-val:hover {
      background: rgba(56, 189, 248, 0.18);
    }
    .reg-val.changed {
      color: #fbbf24;
      font-weight: 700;
    }

    .reg-input {
      width: 82px;
      background: #090d16;
      color: #fbbf24;
      border: 1px solid #f59e0b;
      border-radius: 3px;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.71rem;
      padding: 0 4px;
      outline: none;
    }
  `]
})
export class RegisterInspectorComponent {
  public emu = inject(EmulatorService);

  public isConnected = computed(() => this.emu.connectionState() === 'connected');
  public showSplit = computed(() => this.emu.inspectionMode() === 'split');
  public showCpu0 = computed(() => this.emu.inspectionMode() !== 'cpu1');
  public showCpu1 = computed(() => this.emu.inspectionMode() !== 'cpu0');

  public editingKey = signal<string | null>(null);
  public editValue = signal<string>('');

  public cpu0Entries = computed<RegisterEntry[]>(() =>
    this.buildEntries(Core.Cpu0, this.emu.cpu0Registers(), this.emu.cpu0PrevRegisters())
  );

  public cpu1Entries = computed<RegisterEntry[]>(() =>
    this.buildEntries(Core.Cpu1, this.emu.cpu1Registers(), this.emu.cpu1PrevRegisters())
  );

  public deltaCount = computed(() => {
    const c0 = this.showCpu0() ? this.cpu0Entries().filter((e) => e.changed).length : 0;
    const c1 = this.showCpu1() && this.emu.cpu1Attached() ? this.cpu1Entries().filter((e) => e.changed).length : 0;
    return c0 + c1;
  });

  private buildEntries(
    core: Core,
    curr: Record<string, number>,
    prev: Record<string, number>
  ): RegisterEntry[] {
    const prevHasKeys = Object.keys(prev).length > 0;
    return REG_SPECS.map((spec) => {
      const val = curr[spec.name] ?? 0;
      const prevVal = prev[spec.name];
      const changed = prevHasKeys && prevVal !== undefined && prevVal !== val;
      return {
        key: `${core}:${spec.reg}`,
        core,
        name: spec.name,
        reg: spec.reg,
        value: val,
        hex: (val >>> 0).toString(16).padStart(8, '0'),
        changed,
      };
    });
  }

  public refresh(): void {
    void this.emu.refreshRegisters();
  }

  public startEdit(item: RegisterEntry): void {
    if (!this.isConnected()) return;
    this.editingKey.set(item.key);
    this.editValue.set(`0x${item.hex}`);
  }

  public cancelEdit(): void {
    this.editingKey.set(null);
  }

  public saveEdit(item: RegisterEntry): void {
    const raw = this.editValue().trim();
    const parsed = raw.startsWith('0x') || raw.startsWith('0X')
      ? parseInt(raw.slice(2), 16)
      : parseInt(raw, 10);
    if (!isNaN(parsed)) {
      void this.emu.writeRegister(item.reg, parsed >>> 0, item.core);
    }
    this.editingKey.set(null);
  }
}
