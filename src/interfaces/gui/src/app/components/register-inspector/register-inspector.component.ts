import { Component, inject, computed, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { EmulatorService } from '../../services/emulator.service';
import { Register } from 'ra8-rpc-client';

interface RegisterEntry {
  name: string;
  reg: Register;
  value: number;
  hex: string;
  changed: boolean;
}

@Component({
  selector: 'app-register-inspector',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="registers-card">
      <div class="card-header">
        <span class="title">CPU REGISTERS</span>
        <button
          type="button"
          class="refresh-btn"
          (click)="refresh()"
          [disabled]="!isConnected()"
          title="Refresh Registers"
        >
          ↻
        </button>
      </div>

      <div class="reg-sections">
        <!-- Pointers (PC, LR, SP) -->
        <div class="reg-group">
          <div class="group-title">POINTERS & CONTROL</div>
          <div class="reg-grid">
            <div *ngFor="let item of pointerRegs()" class="reg-row">
              <span class="reg-name">{{ item.name.toUpperCase() }}</span>
              <div class="reg-val-container">
                <span
                  *ngIf="editingReg() !== item.reg"
                  class="reg-val"
                  [class.changed]="item.changed"
                  (click)="startEdit(item)"
                  title="Click to edit value"
                >
                  0x{{ item.hex }}
                </span>
                <input
                  *ngIf="editingReg() === item.reg"
                  type="text"
                  class="reg-edit-input"
                  [ngModel]="editValue()"
                  (ngModelChange)="editValue.set($event)"
                  (keydown.enter)="saveEdit(item.reg)"
                  (keydown.escape)="cancelEdit()"
                  (blur)="cancelEdit()"
                  autofocus
                />
              </div>
            </div>
          </div>
        </div>

        <!-- General Purpose Low (R0-R7) -->
        <div class="reg-group">
          <div class="group-title">GENERAL (R0 - R7)</div>
          <div class="reg-grid">
            <div *ngFor="let item of lowRegs()" class="reg-row">
              <span class="reg-name">{{ item.name.toUpperCase() }}</span>
              <div class="reg-val-container">
                <span
                  *ngIf="editingReg() !== item.reg"
                  class="reg-val"
                  [class.changed]="item.changed"
                  (click)="startEdit(item)"
                  title="Click to edit value"
                >
                  0x{{ item.hex }}
                </span>
                <input
                  *ngIf="editingReg() === item.reg"
                  type="text"
                  class="reg-edit-input"
                  [ngModel]="editValue()"
                  (ngModelChange)="editValue.set($event)"
                  (keydown.enter)="saveEdit(item.reg)"
                  (keydown.escape)="cancelEdit()"
                  (blur)="cancelEdit()"
                  autofocus
                />
              </div>
            </div>
          </div>
        </div>

        <!-- General Purpose High (R8-R12) -->
        <div class="reg-group">
          <div class="group-title">GENERAL (R8 - R12)</div>
          <div class="reg-grid">
            <div *ngFor="let item of highRegs()" class="reg-row">
              <span class="reg-name">{{ item.name.toUpperCase() }}</span>
              <div class="reg-val-container">
                <span
                  *ngIf="editingReg() !== item.reg"
                  class="reg-val"
                  [class.changed]="item.changed"
                  (click)="startEdit(item)"
                  title="Click to edit value"
                >
                  0x{{ item.hex }}
                </span>
                <input
                  *ngIf="editingReg() === item.reg"
                  type="text"
                  class="reg-edit-input"
                  [ngModel]="editValue()"
                  (ngModelChange)="editValue.set($event)"
                  (keydown.enter)="saveEdit(item.reg)"
                  (keydown.escape)="cancelEdit()"
                  (blur)="cancelEdit()"
                  autofocus
                />
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  `,
  styles: [`
    .registers-card {
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

    .reg-sections {
      padding: 8px;
      display: flex;
      flex-direction: column;
      gap: 10px;
      max-height: 480px;
      overflow-y: auto;
    }

    .reg-group {
      display: flex;
      flex-direction: column;
      gap: 4px;
    }

    .group-title {
      font-size: 0.65rem;
      font-weight: 700;
      color: var(--text-secondary);
      letter-spacing: 0.05em;
    }

    .reg-grid {
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 4px 8px;
    }

    .reg-row {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 2px 6px;
      background: #181b20;
      border: 1px solid #232730;
      border-radius: 4px;
      font-family: monospace;
      font-size: 0.75rem;
    }

    .reg-name {
      color: #94a3b8;
      font-weight: 600;
      min-width: 32px;
    }

    .reg-val-container {
      display: flex;
      align-items: center;
    }

    .reg-val {
      color: #f1f5f9;
      cursor: pointer;
      padding: 1px 4px;
      border-radius: 2px;
      transition: background 0.15s;
    }
    .reg-val:hover {
      background: #334155;
    }
    .reg-val.changed {
      color: #38bdf8;
      font-weight: bold;
      background: rgba(56, 189, 248, 0.15);
    }

    .reg-edit-input {
      width: 85px;
      font-family: monospace;
      font-size: 0.75rem;
      background: #0f172a;
      color: #38bdf8;
      border: 1px solid #38bdf8;
      border-radius: 2px;
      padding: 0 4px;
      outline: none;
    }
  `]
})
export class RegisterInspectorComponent {
  private emu = inject(EmulatorService);

  public isConnected = computed(() => this.emu.connectionState() === 'connected');
  public editingReg = signal<Register | null>(null);
  public editValue = signal<string>('');

  private allRegs = computed<RegisterEntry[]>(() => {
    const curr = this.emu.registers();
    const prev = this.emu.previousRegisters();

    const regMap: Array<{ name: string; reg: Register }> = [
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

    return regMap.map((item) => {
      const val = curr[item.name] ?? 0;
      const prevVal = prev[item.name];
      const changed = prevVal !== undefined && prevVal !== val;
      return {
        name: item.name,
        reg: item.reg,
        value: val,
        hex: (val >>> 0).toString(16).padStart(8, '0'),
        changed
      };
    });
  });

  public pointerRegs = computed(() => {
    return this.allRegs().filter((r) => ['pc', 'sp', 'lr', 'xpsr', 'msp', 'psp'].includes(r.name));
  });

  public lowRegs = computed(() => {
    return this.allRegs().filter((r) => ['r0', 'r1', 'r2', 'r3', 'r4', 'r5', 'r6', 'r7'].includes(r.name));
  });

  public highRegs = computed(() => {
    return this.allRegs().filter((r) => ['r8', 'r9', 'r10', 'r11', 'r12'].includes(r.name));
  });

  public refresh(): void {
    void this.emu.refreshRegisters();
  }

  public startEdit(item: RegisterEntry): void {
    this.editingReg.set(item.reg);
    this.editValue.set(`0x${item.hex}`);
  }

  public cancelEdit(): void {
    this.editingReg.set(null);
  }

  public saveEdit(reg: Register): void {
    const raw = this.editValue().trim();
    const parsed = raw.startsWith('0x') || raw.startsWith('0X')
      ? parseInt(raw.slice(2), 16)
      : parseInt(raw, 10);

    if (!isNaN(parsed)) {
      void this.emu.writeRegister(reg, parsed >>> 0);
    }
    this.editingReg.set(null);
  }
}
