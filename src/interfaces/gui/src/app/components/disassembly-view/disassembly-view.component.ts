import { Component, inject, computed, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { EmulatorService } from '../../services/emulator.service';
import { Core, DisasmRow } from 'ra8-rpc-client';

interface ViewInstruction {
  address: number;
  hex: string;
  mnemonic: string;
  operands: string;
  symbol: string;
  isCurrentPc: boolean;
  hasBreakpoint: boolean;
}

@Component({
  selector: 'app-disassembly-view',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="pane-card">
      <div class="pane-header">
        <div class="header-left">
          <span class="pane-title">Authoritative Disassembly</span>
          <span class="engine-tag">Zig Armv8.1-M / Helium Decoder</span>
        </div>
        <div class="header-right">
          <button
            type="button"
            class="follow-btn"
            [class.active]="followPc()"
            (click)="toggleFollowPc()"
            title="Track Program Counter automatically on step/halt"
          >
            Follow PC
          </button>
          <div class="jump-box">
            <input
              type="text"
              class="jump-input"
              placeholder="0x02000000"
              [ngModel]="jumpAddressText()"
              (ngModelChange)="jumpAddressText.set($event)"
              (keydown.enter)="jumpToAddress()"
            />
            <button type="button" class="jump-btn" (click)="jumpToAddress()">Go</button>
          </div>
        </div>
      </div>

      <!-- Synchronized Dual-Core Split or Focused Stream -->
      <div class="lanes-grid" [class.split]="showSplit()">
        <!-- CPU0 (Cortex-M85) Disassembly Stream -->
        <div *ngIf="showCpu0()" class="core-lane">
          <div class="lane-subheader m85">
            <span>CPU0 • Cortex-M85</span>
            <code>PC 0x{{ toHex8(emu.cpu0Pc()) }}</code>
          </div>
          <div class="disasm-scroll">
            <div *ngIf="cpu0Rows().length === 0" class="empty-state">
              Connect emulator backend to stream Cortex-M85 instructions
            </div>

            <table *ngIf="cpu0Rows().length > 0" class="disasm-table">
              <tbody>
                <ng-container *ngFor="let row of cpu0Rows()">
                  <tr *ngIf="row.symbol" class="symbol-row">
                    <td colspan="4">&lt;{{ row.symbol }}&gt;:</td>
                  </tr>
                  <tr class="instr-row" [class.current-pc]="row.isCurrentPc">
                    <td class="col-bp" (click)="toggleBp(row.address, Core.Cpu0)">
                      <span class="bp-dot" [class.active]="row.hasBreakpoint">●</span>
                      <span *ngIf="row.isCurrentPc" class="pc-arrow">▶</span>
                    </td>
                    <td class="col-addr">0x{{ toHex8(row.address) }}</td>
                    <td class="col-hex">{{ row.hex }}</td>
                    <td class="col-asm">
                      <span class="mnemonic">{{ row.mnemonic }}</span>
                      <span class="operands">{{ row.operands }}</span>
                    </td>
                  </tr>
                </ng-container>
              </tbody>
            </table>
          </div>
        </div>

        <!-- CPU1 (Cortex-M33) Disassembly Stream -->
        <div *ngIf="showCpu1()" class="core-lane">
          <div class="lane-subheader m33">
            <span>CPU1 • Cortex-M33</span>
            <code *ngIf="emu.cpu1Attached()">PC 0x{{ toHex8(emu.cpu1Pc()) }}</code>
            <code *ngIf="!emu.cpu1Attached()">CLOCK-GATED</code>
          </div>
          <div class="disasm-scroll">
            <div *ngIf="!emu.cpu1Attached()" class="empty-state">
              Companion Cortex-M33 core is clock-gated (load dual-core ELF or --companion image to activate)
            </div>
            <div *ngIf="emu.cpu1Attached() && cpu1Rows().length === 0" class="empty-state">
              Halt CPU1 to stream Cortex-M33 instructions
            </div>

            <table *ngIf="emu.cpu1Attached() && cpu1Rows().length > 0" class="disasm-table">
              <tbody>
                <ng-container *ngFor="let row of cpu1Rows()">
                  <tr *ngIf="row.symbol" class="symbol-row">
                    <td colspan="4">&lt;{{ row.symbol }}&gt;:</td>
                  </tr>
                  <tr class="instr-row" [class.current-pc]="row.isCurrentPc">
                    <td class="col-bp" (click)="toggleBp(row.address, Core.Cpu1)">
                      <span class="bp-dot" [class.active]="row.hasBreakpoint">●</span>
                      <span *ngIf="row.isCurrentPc" class="pc-arrow">▶</span>
                    </td>
                    <td class="col-addr">0x{{ toHex8(row.address) }}</td>
                    <td class="col-hex">{{ row.hex }}</td>
                    <td class="col-asm">
                      <span class="mnemonic">{{ row.mnemonic }}</span>
                      <span class="operands">{{ row.operands }}</span>
                    </td>
                  </tr>
                </ng-container>
              </tbody>
            </table>
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
      flex-wrap: wrap;
      gap: 8px;
    }

    .header-left,
    .header-right {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .pane-title {
      font-size: 0.8rem;
      font-weight: 600;
      color: #f1f5f9;
    }

    .engine-tag {
      font-size: 0.64rem;
      font-family: "JetBrains Mono", monospace;
      color: #38bdf8;
      background: rgba(56, 189, 248, 0.1);
      border: 1px solid rgba(56, 189, 248, 0.22);
      padding: 1px 6px;
      border-radius: 4px;
    }

    .follow-btn {
      background: rgba(30, 41, 59, 0.7);
      border: 1px solid rgba(255, 255, 255, 0.1);
      color: #94a3b8;
      font-size: 0.69rem;
      font-weight: 600;
      padding: 3px 8px;
      border-radius: 5px;
      cursor: pointer;
    }
    .follow-btn.active {
      background: rgba(2, 132, 199, 0.22);
      color: #38bdf8;
      border-color: rgba(56, 189, 248, 0.45);
    }

    .jump-box {
      display: inline-flex;
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 5px;
      overflow: hidden;
      background: #090d16;
    }

    .jump-input {
      background: transparent;
      border: none;
      color: #f1f5f9;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.7rem;
      padding: 3px 7px;
      width: 92px;
      outline: none;
    }

    .jump-btn {
      background: rgba(51, 65, 85, 0.8);
      border: none;
      color: #e2e8f0;
      font-size: 0.69rem;
      font-weight: 600;
      padding: 3px 8px;
      cursor: pointer;
    }
    .jump-btn:hover { background: #475569; }

    .lanes-grid {
      display: grid;
      grid-template-columns: 1fr;
    }
    .lanes-grid.split {
      grid-template-columns: 1fr 1fr;
    }
    @media (max-width: 960px) {
      .lanes-grid.split {
        grid-template-columns: 1fr;
      }
    }

    .core-lane + .core-lane {
      border-left: 1px solid rgba(255, 255, 255, 0.07);
    }

    .lane-subheader {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 4px 10px;
      font-size: 0.68rem;
      font-weight: 600;
      background: rgba(9, 13, 22, 0.7);
      border-bottom: 1px solid rgba(255, 255, 255, 0.06);
    }
    .lane-subheader.m85 { color: #38bdf8; }
    .lane-subheader.m33 { color: #c084fc; }
    .lane-subheader code {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.66rem;
      color: #94a3b8;
    }

    .disasm-scroll {
      max-height: 270px;
      overflow-y: auto;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.72rem;
    }

    .empty-state {
      padding: 24px 14px;
      text-align: center;
      color: #64748b;
      font-size: 0.72rem;
    }

    .disasm-table {
      width: 100%;
      border-collapse: collapse;
    }

    .symbol-row td {
      padding: 5px 8px 2px;
      color: #34d399;
      font-weight: 700;
      font-size: 0.69rem;
      background: rgba(16, 185, 129, 0.06);
      border-top: 1px solid rgba(52, 211, 153, 0.14);
    }

    .instr-row {
      border-bottom: 1px solid rgba(255, 255, 255, 0.035);
    }
    .instr-row:hover {
      background: rgba(30, 41, 59, 0.45);
    }
    .instr-row.current-pc {
      background: rgba(56, 189, 248, 0.14);
      box-shadow: inset 2px 0 0 #38bdf8;
    }

    .col-bp {
      width: 28px;
      text-align: center;
      cursor: pointer;
      padding: 2px 4px;
      white-space: nowrap;
    }

    .bp-dot {
      color: rgba(100, 116, 139, 0.35);
      font-size: 0.72rem;
      transition: color 0.12s;
    }
    .col-bp:hover .bp-dot { color: #f87171; }
    .bp-dot.active {
      color: #ef4444;
      text-shadow: 0 0 6px #ef4444;
    }

    .pc-arrow {
      color: #38bdf8;
      font-size: 0.62rem;
      margin-left: 2px;
    }

    .col-addr {
      width: 84px;
      color: #94a3b8;
      padding: 2px 5px;
    }

    .col-hex {
      width: 82px;
      color: #64748b;
      padding: 2px 5px;
    }

    .col-asm {
      padding: 2px 6px;
    }

    .mnemonic {
      color: #f472b6;
      font-weight: 600;
      margin-right: 7px;
      display: inline-block;
      min-width: 44px;
    }

    .operands {
      color: #e2e8f0;
    }
  `]
})
export class DisassemblyViewComponent {
  public emu = inject(EmulatorService);
  public Core = Core;

  public followPc = signal<boolean>(true);
  public jumpAddressText = signal<string>('');

  public showSplit = computed(() => this.emu.inspectionMode() === 'split');
  public showCpu0 = computed(() => this.emu.inspectionMode() !== 'cpu1');
  public showCpu1 = computed(() => this.emu.inspectionMode() !== 'cpu0');

  public cpu0Rows = computed<ViewInstruction[]>(() =>
    this.mapRows(this.emu.cpu0Disasm(), this.emu.cpu0Pc(), this.emu.cpu0Breakpoints())
  );

  public cpu1Rows = computed<ViewInstruction[]>(() =>
    this.mapRows(this.emu.cpu1Disasm(), this.emu.cpu1Pc(), this.emu.cpu1Breakpoints())
  );

  private mapRows(
    rows: DisasmRow[],
    pc: number,
    bps: Map<number, number>
  ): ViewInstruction[] {
    const normalizedPc = pc & ~1;
    return rows.map((r) => {
      const size = r.size || 2;
      const hexParts: string[] = [];
      for (let i = 0; i < size && i < r.raw.length; i++) {
        hexParts.push((r.raw[i] ?? 0).toString(16).padStart(2, '0'));
      }
      const trimmed = (r.decoded && r.text ? r.text : '.short 0x' + hexParts.join('')).trim();
      const spaceIdx = trimmed.search(/\s/);
      const mnemonic = spaceIdx === -1 ? trimmed : trimmed.slice(0, spaceIdx);
      const operands = spaceIdx === -1 ? '' : trimmed.slice(spaceIdx + 1).trim();

      return {
        address: r.address,
        hex: hexParts.join(' '),
        mnemonic,
        operands,
        symbol: r.symbol,
        isCurrentPc: (r.address & ~1) === normalizedPc,
        hasBreakpoint: bps.has(r.address & ~1),
      };
    });
  }

  public toggleFollowPc(): void {
    const next = !this.followPc();
    this.followPc.set(next);
    if (next) {
      void this.emu.refreshDisassembly(Core.Cpu0);
      if (this.emu.cpu1Attached()) {
        void this.emu.refreshDisassembly(Core.Cpu1);
      }
    }
  }

  public jumpToAddress(): void {
    const raw = this.jumpAddressText().trim();
    if (!raw) return;
    const addr = raw.startsWith('0x') || raw.startsWith('0X')
      ? parseInt(raw.slice(2), 16)
      : parseInt(raw, 16);
    if (!isNaN(addr)) {
      this.followPc.set(false);
      const targetCore = this.emu.inspectionMode() === 'cpu1' ? Core.Cpu1 : Core.Cpu0;
      void this.emu.refreshDisassembly(targetCore, addr >>> 0, 28);
    }
  }

  public toggleBp(addr: number, core: Core): void {
    void this.emu.toggleBreakpoint(addr, core);
  }

  public toHex8(val: number): string {
    return (val >>> 0).toString(16).padStart(8, '0');
  }
}
