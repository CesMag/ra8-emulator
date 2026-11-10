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
    <div class="disasm-pane">
      <!-- Sub-Toolbar -->
      <div class="disasm-subtoolbar">
        <div class="sub-left">
          <span class="view-label">Armv8.1-M / Helium Stream</span>
          <button
            *ngIf="isConnected()"
            type="button"
            class="quick-bp-chip font-mono"
            (click)="breakAtMain()"
            title="Set symbolic breakpoint on main() and jump disassembly there"
          >
            ● Break &#64; main
          </button>
        </div>

        <div class="sub-right">
          <button
            type="button"
            class="action-btn"
            [class.active]="followPc()"
            (click)="toggleFollowPc()"
            title="Auto-track Program Counter on step/halt"
          >
            Follow PC
          </button>

          <div class="jump-box">
            <input
              type="text"
              list="disasm-symbol-suggestions"
              class="jump-input font-mono"
              placeholder="Symbol (main) or 0xAddr…"
              [ngModel]="jumpAddressText()"
              (ngModelChange)="jumpAddressText.set($event)"
              (keydown.enter)="jumpToTarget()"
            />
            <datalist id="disasm-symbol-suggestions">
              <option *ngFor="let sym of symbolSuggestions()" [value]="sym"></option>
            </datalist>
            <button
              type="button"
              class="jump-btn"
              [disabled]="!isConnected() || !jumpAddressText().trim()"
              (click)="jumpToTarget()"
              title="Jump disassembly view to symbol or hex address"
            >
              Go
            </button>
            <button
              type="button"
              class="jump-btn bp-btn"
              [disabled]="!isConnected() || !jumpAddressText().trim()"
              (click)="setBreakAtTarget()"
              title="Set execution breakpoint at symbol name or hex address"
            >
              + Break
            </button>
          </div>
        </div>
      </div>

      <!-- Synchronized Dual-Core Split or Focused Stream -->
      <div class="lanes-grid" [class.split]="showSplit()">
        <!-- CPU0 (Cortex-M85) Disassembly Stream -->
        <div *ngIf="showCpu0()" class="core-lane">
          <div class="lane-header m85">
            <div class="lane-left">
              <span class="lane-title">CPU0 • Cortex-M85</span>
              <span *ngIf="cpu0SourceBadge()" class="src-pill font-mono" [title]="cpu0SourceFull()">
                {{ cpu0SourceBadge() }}
              </span>
            </div>
            <code class="lane-pc font-mono">PC 0x{{ toHex8(emu.cpu0Pc()) }}</code>
          </div>
          <div class="disasm-scroll">
            <div *ngIf="cpu0Rows().length === 0" class="empty-state">
              Connect emulator backend or load an <code>.elf</code> image to stream Cortex-M85 instructions
            </div>

            <table *ngIf="cpu0Rows().length > 0" class="disasm-table font-mono">
              <tbody>
                <ng-container *ngFor="let row of cpu0Rows()">
                  <tr *ngIf="row.symbol" class="symbol-row">
                    <td colspan="4">&lt;{{ row.symbol }}&gt;:</td>
                  </tr>
                  <tr class="instr-row" [class.current-pc]="row.isCurrentPc">
                    <td class="col-bp" (click)="toggleBp(row.address, Core.Cpu0)" title="Click to toggle execution breakpoint">
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
          <div class="lane-header m33">
            <div class="lane-left">
              <span class="lane-title">CPU1 • Cortex-M33</span>
              <span *ngIf="cpu1SourceBadge()" class="src-pill font-mono">
                {{ cpu1SourceBadge() }}
              </span>
            </div>
            <code *ngIf="emu.cpu1Attached()" class="lane-pc font-mono">PC 0x{{ toHex8(emu.cpu1Pc()) }}</code>
            <code *ngIf="!emu.cpu1Attached()" class="lane-pc font-mono">CLOCK-GATED</code>
          </div>
          <div class="disasm-scroll">
            <div *ngIf="!emu.cpu1Attached()" class="empty-state">
              Companion Cortex-M33 core is clock-gated (start server with <code>--cpu1 &lt;m33.elf&gt;</code> to activate)
            </div>
            <div *ngIf="emu.cpu1Attached() && cpu1Rows().length === 0" class="empty-state">
              Halt CPU1 to stream Cortex-M33 instructions
            </div>

            <table *ngIf="emu.cpu1Attached() && cpu1Rows().length > 0" class="disasm-table font-mono">
              <tbody>
                <ng-container *ngFor="let row of cpu1Rows()">
                  <tr *ngIf="row.symbol" class="symbol-row">
                    <td colspan="4">&lt;{{ row.symbol }}&gt;:</td>
                  </tr>
                  <tr class="instr-row" [class.current-pc]="row.isCurrentPc">
                    <td class="col-bp" (click)="toggleBp(row.address, Core.Cpu1)" title="Click to toggle execution breakpoint">
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
    .disasm-pane {
      height: 100%;
      display: flex;
      flex-direction: column;
      overflow: hidden;
      background: var(--bg-surface);
    }

    .disasm-subtoolbar {
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

    .view-label {
      font-size: 10px;
      color: var(--text-secondary);
      font-weight: 500;
      white-space: nowrap;
    }

    .quick-bp-chip {
      background: transparent;
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      color: var(--accent-red);
      font-size: 10px;
      font-weight: 600;
      padding: 1px 6px;
      cursor: pointer;
      white-space: nowrap;
      transition: background 0.12s, border-color 0.12s;
    }

    .quick-bp-chip:hover {
      background: var(--bg-well);
      border-color: var(--accent-red);
    }

    .action-btn {
      background: transparent;
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      color: var(--text-secondary);
      font-size: 10px;
      font-weight: 500;
      padding: 2px 7px;
      cursor: pointer;
      white-space: nowrap;
      transition: all 0.12s;
    }

    .action-btn:hover {
      background: var(--bg-well);
      color: var(--text-primary);
    }

    .action-btn.active {
      background: var(--accent-blue-subtle);
      border-color: var(--accent-blue);
      color: var(--accent-blue);
      font-weight: 600;
    }

    .jump-box {
      display: inline-flex;
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      overflow: hidden;
      background: var(--bg-well);
    }

    .jump-input {
      background: transparent;
      border: none;
      color: var(--text-primary);
      font-size: 10px;
      padding: 2px 6px;
      width: 168px;
      outline: none;
    }

    .jump-btn {
      background: var(--border-subtle);
      border: none;
      border-left: 1px solid var(--border-subtle);
      color: var(--text-primary);
      font-size: 10px;
      font-weight: 600;
      padding: 2px 7px;
      cursor: pointer;
      white-space: nowrap;
    }

    .jump-btn:hover:not(:disabled) {
      background: var(--border-strong);
    }

    .jump-btn.bp-btn {
      color: var(--accent-red);
    }

    .jump-btn:disabled {
      opacity: 0.4;
      cursor: not-allowed;
    }

    .lanes-grid {
      flex: 1;
      min-height: 0;
      display: grid;
      grid-template-columns: 1fr;
      overflow: hidden;
    }

    .lanes-grid.split {
      grid-template-columns: 1fr 1fr;
    }

    .core-lane {
      display: flex;
      flex-direction: column;
      min-height: 0;
      overflow: hidden;
    }

    .core-lane + .core-lane {
      border-left: 1px solid var(--border-subtle);
    }

    .lane-header {
      height: 24px;
      min-height: 24px;
      background: var(--bg-well);
      border-bottom: 1px solid var(--border-subtle);
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 8px;
      font-size: 10px;
      font-weight: 600;
      flex-shrink: 0;
      gap: 6px;
    }

    .lane-left {
      display: flex;
      align-items: center;
      gap: 6px;
      min-width: 0;
    }

    .lane-header.m85 .lane-title { color: var(--accent-blue); white-space: nowrap; }
    .lane-header.m33 .lane-title { color: var(--accent-purple); white-space: nowrap; }

    .src-pill {
      font-size: 10px;
      font-weight: 500;
      color: var(--accent-green);
      background: var(--accent-green-subtle);
      padding: 0 5px;
      border-radius: var(--radius-sm);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      max-width: 170px;
    }

    .lane-pc {
      color: var(--text-secondary);
      font-size: 10px;
      white-space: nowrap;
    }

    .disasm-scroll {
      flex: 1;
      min-height: 0;
      overflow-y: auto;
      font-size: 11px;
    }

    .empty-state {
      padding: 30px 14px;
      text-align: center;
      color: var(--text-tertiary);
      font-size: 11px;
      line-height: 1.45;
    }

    .empty-state code {
      font-family: var(--font-mono);
      color: var(--text-secondary);
      background: var(--bg-well);
      padding: 1px 4px;
      border-radius: 3px;
    }

    .disasm-table {
      width: 100%;
      border-collapse: collapse;
      table-layout: fixed;
    }

    .symbol-row td {
      padding: 4px 8px 1px;
      color: var(--accent-green);
      font-weight: 700;
      font-size: 10px;
      background: var(--accent-green-subtle);
      border-top: 1px solid var(--border-subtle);
    }

    .instr-row {
      border-bottom: 1px solid var(--border-subtle);
      height: 20px;
    }

    .instr-row:hover {
      background: var(--bg-well);
    }

    .instr-row.current-pc {
      background: var(--accent-blue-subtle);
      box-shadow: inset 2px 0 0 var(--accent-blue);
    }

    .col-bp {
      width: 24px;
      text-align: center;
      cursor: pointer;
      padding: 0;
      white-space: nowrap;
      user-select: none;
    }

    .bp-dot {
      color: var(--text-tertiary);
      opacity: 0.3;
      font-size: 10px;
      transition: color 0.12s, opacity 0.12s;
    }

    .col-bp:hover .bp-dot {
      color: var(--accent-red);
      opacity: 0.8;
    }

    .bp-dot.active {
      color: var(--accent-red);
      opacity: 1;
    }

    .pc-arrow {
      color: var(--accent-blue);
      font-size: 8px;
      margin-left: 1px;
    }

    .col-addr {
      width: 82px;
      color: var(--text-secondary);
      padding: 0 4px;
    }

    .col-hex {
      width: 78px;
      color: var(--text-tertiary);
      padding: 0 4px;
    }

    .col-asm {
      padding: 0 4px;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .mnemonic {
      color: var(--accent-purple);
      font-weight: 600;
      margin-right: 6px;
      display: inline-block;
      min-width: 42px;
    }

    .operands {
      color: var(--text-primary);
    }
  `]
})
export class DisassemblyViewComponent {
  public emu = inject(EmulatorService);
  public Core = Core;

  public followPc = signal<boolean>(true);
  public jumpAddressText = signal<string>('');

  public isConnected = computed(() => this.emu.connectionState() === 'connected');
  public showSplit = computed(() => this.emu.inspectionMode() === 'split');
  public showCpu0 = computed(() => this.emu.inspectionMode() !== 'cpu1');
  public showCpu1 = computed(() => this.emu.inspectionMode() !== 'cpu0');

  public cpu0SourceBadge = computed(() => {
    const sl = this.emu.cpu0SourceLine();
    if (!sl || !sl.found || !sl.path) return '';
    const base = sl.path.split(/[\\/]/).pop() ?? sl.path;
    return `${base}:${sl.line}`;
  });

  public cpu0SourceFull = computed(() => {
    const sl = this.emu.cpu0SourceLine();
    if (!sl || !sl.found) return '';
    return `${sl.path}:${sl.line}`;
  });

  public cpu1SourceBadge = computed(() => {
    const sl = this.emu.cpu1SourceLine();
    if (!sl || !sl.found || !sl.path) return '';
    const base = sl.path.split(/[\\/]/).pop() ?? sl.path;
    return `${base}:${sl.line}`;
  });

  public symbolSuggestions = computed<string[]>(() => {
    const set = new Set<string>(['main', 'Reset_Handler', 'SysTick_Handler', 'HardFault_Handler']);
    for (const sym of this.emu.cpu0ElfSymbols()) {
      if (sym.kind === 'func' && set.size < 80) set.add(sym.name);
    }
    for (const row of this.emu.cpu0Disasm()) {
      if (row.symbol) set.add(row.symbol);
    }
    return Array.from(set);
  });

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

  private targetCore(): Core {
    return this.emu.inspectionMode() === 'cpu1' && this.emu.cpu1Attached() ? Core.Cpu1 : Core.Cpu0;
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

  public async jumpToTarget(): Promise<void> {
    const raw = this.jumpAddressText().trim();
    if (!raw) return;
    const core = this.targetCore();

    if (/^0x[0-9a-f]+$/i.test(raw) || /^[0-9a-f]{8}$/i.test(raw)) {
      const addr = parseInt(raw.replace(/^0x/i, ''), 16) >>> 0;
      this.followPc.set(false);
      await this.emu.refreshDisassembly(core, addr, 28);
      return;
    }

    // Symbol lookup: first check client-parsed ELF symbols, then current disasm rows
    const syms = core === Core.Cpu1 ? this.emu.cpu1ElfSymbols() : this.emu.cpu0ElfSymbols();
    const symMatch = syms.find((s) => s.name === raw);
    if (symMatch) {
      this.followPc.set(false);
      await this.emu.refreshDisassembly(core, (symMatch.address & ~1) >>> 0, 28);
      return;
    }

    const disasmMatch = (core === Core.Cpu1 ? this.emu.cpu1Disasm() : this.emu.cpu0Disasm()).find(
      (r) => r.symbol === raw
    );
    if (disasmMatch) {
      this.followPc.set(false);
      await this.emu.refreshDisassembly(core, (disasmMatch.address & ~1) >>> 0, 28);
      return;
    }

    // Fallback: set breakpoint by name via backend DWARF/symtab to resolve address, jump, and keep user informed
    const bp = await this.emu.addNamedBreakpoint(raw, core);
    if (bp && !bp.deferred) {
      this.followPc.set(false);
      await this.emu.refreshDisassembly(core, (bp.address & ~1) >>> 0, 28);
    }
  }

  public async setBreakAtTarget(): Promise<void> {
    const raw = this.jumpAddressText().trim();
    if (!raw) return;
    const core = this.targetCore();

    if (/^0x[0-9a-f]+$/i.test(raw)) {
      const addr = parseInt(raw.slice(2), 16) >>> 0;
      await this.emu.toggleBreakpoint(addr, core);
      this.followPc.set(false);
      await this.emu.refreshDisassembly(core, addr & ~1, 28);
    } else {
      const bp = await this.emu.addNamedBreakpoint(raw, core);
      if (bp && !bp.deferred) {
        this.followPc.set(false);
        await this.emu.refreshDisassembly(core, (bp.address & ~1) >>> 0, 28);
      }
    }
    this.jumpAddressText.set('');
  }

  public async breakAtMain(): Promise<void> {
    const core = this.targetCore();
    const bp = await this.emu.addNamedBreakpoint('main', core);
    if (bp && !bp.deferred) {
      this.followPc.set(false);
      await this.emu.refreshDisassembly(core, (bp.address & ~1) >>> 0, 28);
    }
  }

  public toggleBp(addr: number, core: Core): void {
    void this.emu.toggleBreakpoint(addr, core);
  }

  public toHex8(val: number): string {
    return (val >>> 0).toString(16).padStart(8, '0');
  }
}
