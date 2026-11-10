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

function getRegSpecs(): Array<{ name: string; reg: Register }> {
  return [
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
}

@Component({
  selector: 'app-register-inspector',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="registers-pane">
      <!-- Sub-Toolbar -->
      <div class="registers-subtoolbar">
        <div class="sub-left">
          <span class="reg-label">Architectural State</span>
          <span *ngIf="deltaCount() > 0" class="delta-pill font-mono">Δ {{ deltaCount() }} modified</span>
        </div>
        <button
          type="button"
          class="refresh-btn"
          (click)="refresh()"
          [disabled]="!isConnected()"
          title="Refresh registers"
        >
          ↻
        </button>
      </div>

      <!-- Cores Grid -->
      <div class="cores-container" [class.split]="showSplit()">
        <!-- CPU0 (Cortex-M85) -->
        <div *ngIf="showCpu0()" class="core-section">
          <div class="core-header m85">
            <span>CPU0 • Cortex-M85</span>
          </div>
          <div class="reg-grid font-mono">
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
                class="reg-input font-mono"
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
        <div *ngIf="showCpu1()" class="core-section">
          <div class="core-header m33">
            <span>CPU1 • Cortex-M33</span>
          </div>
          <div *ngIf="!emu.cpu1Attached()" class="gated-note">
            CPU1 clock-gated (awaiting dual-core image)
          </div>
          <div *ngIf="emu.cpu1Attached()" class="reg-grid font-mono">
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
                class="reg-input font-mono"
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
    .registers-pane {
      height: 100%;
      display: flex;
      flex-direction: column;
      overflow: hidden;
      background: var(--bg-surface);
    }

    .registers-subtoolbar {
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

    .sub-left {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .reg-label {
      font-size: 10px;
      color: var(--text-secondary);
      font-weight: 500;
    }

    .delta-pill {
      font-size: 10px;
      color: var(--accent-amber);
      background: var(--accent-amber-subtle);
      padding: 1px 6px;
      border-radius: var(--radius-sm);
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

    .cores-container {
      flex: 1;
      min-height: 0;
      overflow-y: auto;
      display: flex;
      flex-direction: column;
    }

    .cores-container.split {
      display: grid;
      grid-template-columns: 1fr 1fr;
    }

    .core-section {
      display: flex;
      flex-direction: column;
    }

    .core-section + .core-section {
      border-top: 1px solid var(--border-subtle);
    }

    .cores-container.split .core-section + .core-section {
      border-top: none;
      border-left: 1px solid var(--border-subtle);
    }

    .core-header {
      height: 22px;
      min-height: 22px;
      background: var(--bg-well);
      border-bottom: 1px solid var(--border-subtle);
      display: flex;
      align-items: center;
      padding: 0 8px;
      font-size: 10px;
      font-weight: 600;
    }

    .core-header.m85 { color: var(--accent-blue); }
    .core-header.m33 { color: var(--accent-purple); }

    .gated-note {
      padding: 16px 12px;
      font-size: 11px;
      color: var(--text-tertiary);
    }

    .reg-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(130px, 1fr));
      gap: 2px 6px;
      padding: 6px 8px;
      font-size: 11px;
    }

    .reg-cell {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 2px 6px;
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      height: 22px;
      transition: border-color 0.15s, background 0.15s;
    }

    .reg-cell.changed {
      border-color: var(--accent-amber);
      background: var(--accent-amber-subtle);
    }

    .reg-name {
      color: var(--text-tertiary);
      font-weight: 600;
      font-size: 10px;
    }

    .reg-val {
      color: var(--text-primary);
      cursor: pointer;
      padding: 0 2px;
      border-radius: 2px;
    }

    .reg-val:hover {
      background: var(--accent-blue-subtle);
      color: var(--accent-blue);
    }

    .reg-val.changed {
      color: var(--accent-amber);
      font-weight: 700;
    }

    .reg-input {
      width: 76px;
      background: var(--bg-surface);
      color: var(--accent-amber);
      border: 1px solid var(--accent-amber);
      border-radius: 2px;
      font-size: 10px;
      padding: 0 3px;
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
    return getRegSpecs().map((spec) => {
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
