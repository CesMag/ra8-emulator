import { Component, inject, computed, signal, effect, OnDestroy } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { EmulatorService } from '../../services/emulator.service';
import { DisassemblerService, DecodedInstruction } from '../../services/disassembler.service';

@Component({
  selector: 'app-disassembly-view',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="disasm-card">
      <div class="card-header">
        <div class="header-left">
          <span class="title">DISASSEMBLY</span>
          <span class="pc-badge">PC: 0x{{ currentPcHex() }}</span>
        </div>
        <div class="header-right">
          <button
            type="button"
            class="follow-btn"
            [class.active]="followPc()"
            (click)="toggleFollowPc()"
            title="Follow Program Counter"
          >
            📌 Follow PC
          </button>
          <div class="jump-box">
            <input
              type="text"
              class="jump-input"
              placeholder="0xAddr"
              [ngModel]="jumpAddressText()"
              (ngModelChange)="jumpAddressText.set($event)"
              (keydown.enter)="jumpToAddress()"
            />
            <button type="button" class="jump-btn" (click)="jumpToAddress()">Go</button>
          </div>
        </div>
      </div>

      <div class="disasm-table-container">
        <div *ngIf="instructions().length === 0" class="empty-state">
          No disassembly available (Connect or halt CPU to inspect instructions)
        </div>

        <table *ngIf="instructions().length > 0" class="disasm-table">
          <thead>
            <tr>
              <th class="col-bp"></th>
              <th class="col-addr">Address</th>
              <th class="col-hex">Opcode</th>
              <th class="col-asm">Instruction</th>
            </tr>
          </thead>
          <tbody>
            <tr
              *ngFor="let instr of instructions()"
              class="disasm-row"
              [class.current-pc]="instr.isCurrentPc"
            >
              <!-- Breakpoint Gutter -->
              <td class="col-bp" (click)="toggleBreakpoint(instr.address)">
                <span
                  class="bp-dot"
                  [class.active]="instr.hasBreakpoint"
                  [title]="instr.hasBreakpoint ? 'Clear Breakpoint' : 'Set Breakpoint'"
                >●</span>
                <span *ngIf="instr.isCurrentPc" class="pc-arrow">▶</span>
              </td>

              <!-- Address -->
              <td class="col-addr">0x{{ toHex8(instr.address) }}</td>

              <!-- Hex Opcode -->
              <td class="col-hex">{{ instr.hex }}</td>

              <!-- Instruction -->
              <td class="col-asm">
                <span class="mnemonic">{{ instr.mnemonic }}</span>
                <span class="operands">{{ instr.operands }}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
  `,
  styles: [`
    .disasm-card {
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
      flex-wrap: wrap;
      gap: 8px;
    }

    .header-left {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .title {
      font-size: 0.75rem;
      font-weight: 700;
      color: var(--text-primary);
    }

    .pc-badge {
      font-size: 0.7rem;
      font-family: monospace;
      color: #38bdf8;
      background: rgba(56, 189, 248, 0.1);
      padding: 1px 6px;
      border-radius: 4px;
    }

    .header-right {
      display: flex;
      align-items: center;
      gap: 6px;
    }

    .follow-btn {
      background: #1e293b;
      border: 1px solid #334155;
      color: #94a3b8;
      font-size: 0.7rem;
      padding: 2px 8px;
      border-radius: 4px;
      cursor: pointer;
    }
    .follow-btn.active {
      background: rgba(56, 189, 248, 0.2);
      color: #38bdf8;
      border-color: #38bdf8;
    }

    .jump-box {
      display: flex;
      border: 1px solid var(--border-color);
      border-radius: 4px;
      overflow: hidden;
    }

    .jump-input {
      background: #0f172a;
      border: none;
      color: #f1f5f9;
      font-family: monospace;
      font-size: 0.7rem;
      padding: 2px 6px;
      width: 90px;
      outline: none;
    }

    .jump-btn {
      background: #334155;
      border: none;
      color: #f1f5f9;
      font-size: 0.7rem;
      padding: 2px 8px;
      cursor: pointer;
    }
    .jump-btn:hover { background: #475569; }

    .disasm-table-container {
      max-height: 280px;
      overflow-y: auto;
      font-family: monospace;
      font-size: 0.75rem;
    }

    .empty-state {
      padding: 24px;
      text-align: center;
      color: #64748b;
      font-style: italic;
    }

    .disasm-table {
      width: 100%;
      border-collapse: collapse;
      user-select: text;
    }

    .disasm-table th {
      background: #181b20;
      color: #64748b;
      font-weight: 600;
      padding: 4px 6px;
      text-align: left;
      font-size: 0.7rem;
      position: sticky;
      top: 0;
      z-index: 2;
    }

    .disasm-row {
      border-bottom: 1px solid #1c2028;
    }
    .disasm-row:hover {
      background: #1e2430;
    }

    .disasm-row.current-pc {
      background: rgba(56, 189, 248, 0.15);
      border-left: 2px solid #38bdf8;
    }

    .col-bp {
      width: 32px;
      text-align: center;
      cursor: pointer;
      padding: 2px;
    }

    .bp-dot {
      color: #334155;
      font-size: 0.8rem;
      line-height: 1;
      transition: color 0.15s;
    }
    .col-bp:hover .bp-dot { color: #f87171; }
    .bp-dot.active {
      color: #ef4444;
      text-shadow: 0 0 6px #ef4444;
    }

    .pc-arrow {
      color: #38bdf8;
      font-size: 0.65rem;
      margin-left: 2px;
    }

    .col-addr {
      width: 90px;
      color: #94a3b8;
      padding: 2px 6px;
    }

    .col-hex {
      width: 110px;
      color: #64748b;
      padding: 2px 6px;
    }

    .col-asm {
      padding: 2px 6px;
    }

    .mnemonic {
      color: #f472b6;
      font-weight: 600;
      margin-right: 8px;
      display: inline-block;
      min-width: 45px;
    }

    .operands {
      color: #e2e8f0;
    }
  `]
})
export class DisassemblyViewComponent {
  private emu = inject(EmulatorService);
  private disasm = inject(DisassemblerService);

  public followPc = signal<boolean>(true);
  public jumpAddressText = signal<string>('');
  public viewBaseAddress = signal<number | null>(null);
  public instructions = signal<DecodedInstruction[]>([]);

  public currentPc = computed(() => {
    return this.emu.registers()['pc'] ?? 0;
  });

  public currentPcHex = computed(() => {
    return this.toHex8(this.currentPc());
  });

  constructor() {
    // When PC changes or breakpoints change, refresh disassembly view
    effect(() => {
      const pc = this.currentPc();
      const bps = this.emu.breakpoints();
      if (this.followPc() || this.viewBaseAddress() === null) {
        this.fetchDisassembly(pc, bps);
      } else {
        this.fetchDisassembly(this.viewBaseAddress()!, bps);
      }
    });
  }

  public toggleFollowPc(): void {
    const next = !this.followPc();
    this.followPc.set(next);
    if (next) {
      this.fetchDisassembly(this.currentPc(), this.emu.breakpoints());
    }
  }

  public jumpToAddress(): void {
    const raw = this.jumpAddressText().trim();
    if (!raw) return;
    const addr = raw.startsWith('0x') || raw.startsWith('0X')
      ? parseInt(raw.slice(2), 16)
      : parseInt(raw, 10);

    if (!isNaN(addr)) {
      this.followPc.set(false);
      this.viewBaseAddress.set(addr >>> 0);
      this.fetchDisassembly(addr >>> 0, this.emu.breakpoints());
    }
  }

  public toggleBreakpoint(addr: number): void {
    void this.emu.toggleBreakpoint(addr);
  }

  private async fetchDisassembly(targetAddr: number, bps: Set<number>): Promise<void> {
    // Read 64 bytes around target address (-16 to +48)
    const startAddr = Math.max(0, (targetAddr - 16) & ~1);
    const readLen = 64;

    const bytes = await this.emu.readMemory(startAddr, readLen);
    if (bytes && bytes.length > 0) {
      const decoded = this.disasm.disassemble(bytes, startAddr, this.currentPc(), bps);
      this.instructions.set(decoded);
    } else {
      this.instructions.set([]);
    }
  }

  public toHex8(val: number): string {
    return (val >>> 0).toString(16).padStart(8, '0');
  }
}
