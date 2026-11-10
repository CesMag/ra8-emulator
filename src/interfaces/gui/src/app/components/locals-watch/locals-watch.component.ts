import { Component, inject, computed, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { EmulatorService, BreakpointEntry, WatchpointEntry } from '../../services/emulator.service';
import { Access, Core } from 'ra8-rpc-client';

@Component({
  selector: 'app-locals-watch',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="locals-watch-pane">
      <!-- Left Column: DWARF Local Variables -->
      <section class="sub-pane locals-col">
        <div class="sub-header">
          <div class="sub-title-group">
            <span class="sub-title">Local Variables</span>
            <span *ngIf="activeSourceBadge()" class="src-badge font-mono">{{ activeSourceBadge() }}</span>
          </div>
          <span class="core-tag font-mono">{{ focusedCore() === Core.Cpu1 ? 'CPU1 • M33' : 'CPU0 • M85' }}</span>
        </div>

        <div class="sub-scroll">
          <div *ngIf="activeLocals().length === 0" class="empty-note">
            <span *ngIf="emu.connectionState() !== 'connected'">Connect backend and halt inside a C/Zig function to inspect DWARF locals.</span>
            <span *ngIf="emu.connectionState() === 'connected'">No DWARF local variables in scope at current PC (compile with <code>-g</code> and step into a function).</span>
          </div>

          <table *ngIf="activeLocals().length > 0" class="lw-table font-mono">
            <thead>
              <tr>
                <th>Variable</th>
                <th>Type</th>
                <th>Value</th>
                <th>Where</th>
              </tr>
            </thead>
            <tbody>
              <tr *ngFor="let item of activeLocals()">
                <td class="var-name">{{ item.name }}</td>
                <td class="var-type">{{ item.typeName }}</td>
                <td class="var-val">
                  <span class="val-dec" *ngIf="item.valueDec">{{ item.valueDec }}</span>
                  <span class="val-hex">{{ item.valueHex }}</span>
                </td>
                <td class="var-loc">{{ item.locationLabel }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <!-- Right Column: Breakpoints & Memory Watchpoints -->
      <section class="sub-pane points-col">
        <div class="sub-header">
          <span class="sub-title">Breakpoints &amp; Watchpoints</span>
          <span class="count-pill font-mono">{{ breakpoints().length + watchpoints().length }}</span>
        </div>

        <!-- Quick Add Bar -->
        <div class="quick-bar">
          <input
            type="text"
            class="quick-input font-mono"
            placeholder="Symbol (main) or 0xAddr…"
            [ngModel]="quickTarget()"
            (ngModelChange)="quickTarget.set($event)"
            (keydown.enter)="quickAddBreak()"
          />
          <button
            type="button"
            class="quick-btn"
            [disabled]="!isConnected() || !quickTarget().trim()"
            (click)="quickAddBreak()"
            title="Add execution breakpoint by symbol name or hex address"
          >
            + Break
          </button>
          <button
            type="button"
            class="quick-btn watch"
            [disabled]="!isConnected() || !quickTarget().trim()"
            (click)="quickAddWatch()"
            title="Add 4-byte write watchpoint on hex address or global symbol"
          >
            + Watch
          </button>
        </div>

        <div class="sub-scroll">
          <div *ngIf="breakpoints().length === 0 && watchpoints().length === 0" class="empty-note">
            No active stops. Type <code>main</code> above, click a gutter dot in Disassembly, or click Watch in Memory Hex.
          </div>

          <div class="points-list font-mono" *ngIf="breakpoints().length > 0 || watchpoints().length > 0">
            <!-- Execution Breakpoints -->
            <div *ngFor="let bp of breakpoints()" class="point-row">
              <span class="pt-badge bp">BP</span>
              <span class="pt-core">{{ bp.core === Core.Cpu0 ? 'M85' : 'M33' }}</span>
              <span class="pt-label" [title]="bp.label">{{ bp.label }}</span>
              <span class="pt-addr" *ngIf="!bp.deferred">0x{{ toHex8(bp.address) }}</span>
              <span class="pt-addr pending" *ngIf="bp.deferred">pending</span>
              <button type="button" class="pt-del" (click)="removeBp(bp)" title="Remove breakpoint">✕</button>
            </div>

            <!-- Hardware Memory Watchpoints -->
            <div *ngFor="let wp of watchpoints()" class="point-row">
              <span class="pt-badge wp">{{ accessLabel(wp.access) }}</span>
              <span class="pt-core">{{ wp.core === Core.Cpu0 ? 'M85' : 'M33' }}</span>
              <button
                type="button"
                class="pt-link font-mono"
                (click)="jumpMem(wp.first)"
                title="Inspect watched address in Memory Hex"
              >
                0x{{ toHex8(wp.first) }}
              </button>
              <span class="pt-addr">{{ wp.last - wp.first + 1 }}B</span>
              <button type="button" class="pt-del" (click)="removeWp(wp)" title="Remove watchpoint">✕</button>
            </div>
          </div>
        </div>
      </section>
    </div>
  `,
  styles: [`
    .locals-watch-pane {
      height: 100%;
      display: grid;
      grid-template-columns: 1.15fr 1fr;
      overflow: hidden;
      background: var(--bg-surface);
    }

    .sub-pane {
      display: flex;
      flex-direction: column;
      min-height: 0;
      overflow: hidden;
    }

    .points-col {
      border-left: 1px solid var(--border-subtle);
    }

    .sub-header {
      height: 26px;
      min-height: 26px;
      padding: 0 10px;
      background: var(--bg-well);
      border-bottom: 1px solid var(--border-subtle);
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      flex-shrink: 0;
    }

    .sub-title-group {
      display: flex;
      align-items: center;
      gap: 6px;
      min-width: 0;
    }

    .sub-title {
      font-size: 10px;
      font-weight: 600;
      color: var(--text-secondary);
      white-space: nowrap;
    }

    .src-badge {
      font-size: 10px;
      color: var(--accent-blue);
      background: var(--accent-blue-subtle);
      padding: 1px 6px;
      border-radius: var(--radius-sm);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      max-width: 220px;
    }

    .core-tag, .count-pill {
      font-size: 10px;
      color: var(--text-secondary);
      background: var(--border-subtle);
      padding: 1px 5px;
      border-radius: var(--radius-sm);
    }

    .quick-bar {
      display: flex;
      align-items: center;
      gap: 4px;
      padding: 4px 8px;
      border-bottom: 1px solid var(--border-subtle);
      background: var(--bg-surface);
      flex-shrink: 0;
    }

    .quick-input {
      flex: 1;
      min-width: 0;
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      color: var(--text-primary);
      font-size: 10px;
      padding: 3px 6px;
      outline: none;
    }

    .quick-input:focus {
      border-color: var(--accent-blue);
    }

    .quick-btn {
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      color: var(--text-primary);
      font-size: 10px;
      font-weight: 600;
      padding: 3px 7px;
      cursor: pointer;
      white-space: nowrap;
    }

    .quick-btn:hover:not(:disabled) {
      background: var(--accent-blue-subtle);
      border-color: var(--accent-blue);
      color: var(--accent-blue);
    }

    .quick-btn.watch:hover:not(:disabled) {
      background: var(--accent-amber-subtle);
      border-color: var(--accent-amber);
      color: var(--accent-amber);
    }

    .quick-btn:disabled {
      opacity: 0.4;
      cursor: not-allowed;
    }

    .sub-scroll {
      flex: 1;
      min-height: 0;
      overflow-y: auto;
      font-size: 11px;
    }

    .empty-note {
      padding: 18px 12px;
      color: var(--text-tertiary);
      font-size: 11px;
      line-height: 1.45;
    }

    .empty-note code {
      font-family: var(--font-mono);
      color: var(--text-secondary);
      background: var(--bg-well);
      padding: 1px 4px;
      border-radius: 3px;
    }

    .lw-table {
      width: 100%;
      border-collapse: collapse;
      font-variant-numeric: tabular-nums;
    }

    .lw-table th {
      text-align: left;
      font-size: 10px;
      font-weight: 600;
      color: var(--text-tertiary);
      background: var(--bg-well);
      padding: 3px 8px;
      border-bottom: 1px solid var(--border-subtle);
      position: sticky;
      top: 0;
    }

    .lw-table td {
      padding: 3px 8px;
      border-bottom: 1px solid var(--border-subtle);
      font-size: 11px;
    }

    .var-name {
      color: var(--text-primary);
      font-weight: 600;
    }

    .var-type {
      color: var(--text-tertiary);
      font-size: 10px;
    }

    .var-val {
      display: flex;
      align-items: baseline;
      gap: 6px;
    }

    .val-dec {
      color: var(--accent-amber);
      font-weight: 600;
    }

    .val-hex {
      color: var(--text-secondary);
      font-size: 10px;
    }

    .var-loc {
      color: var(--text-tertiary);
      font-size: 10px;
    }

    .points-list {
      display: flex;
      flex-direction: column;
    }

    .point-row {
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 4px 8px;
      border-bottom: 1px solid var(--border-subtle);
      font-size: 10px;
      font-variant-numeric: tabular-nums;
    }

    .pt-badge {
      padding: 1px 4px;
      border-radius: 3px;
      font-weight: 700;
      font-size: 9px;
    }

    .pt-badge.bp {
      background: rgba(255, 69, 58, 0.16);
      color: var(--accent-red);
    }

    .pt-badge.wp {
      background: var(--accent-amber-subtle);
      color: var(--accent-amber);
    }

    .pt-core {
      color: var(--text-tertiary);
    }

    .pt-label {
      flex: 1;
      min-width: 0;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      color: var(--text-primary);
      font-weight: 500;
    }

    .pt-link {
      flex: 1;
      text-align: left;
      background: transparent;
      border: none;
      color: var(--accent-blue);
      cursor: pointer;
      padding: 0;
      font-size: 10px;
    }

    .pt-link:hover {
      text-decoration: underline;
    }

    .pt-addr {
      color: var(--text-secondary);
    }

    .pt-addr.pending {
      color: var(--accent-amber);
    }

    .pt-del {
      background: transparent;
      border: none;
      color: var(--text-tertiary);
      cursor: pointer;
      padding: 0 3px;
      font-size: 10px;
    }

    .pt-del:hover {
      color: var(--accent-red);
    }
  `]
})
export class LocalsWatchComponent {
  public emu = inject(EmulatorService);
  public Core = Core;

  public quickTarget = signal<string>('');

  public isConnected = computed(() => this.emu.connectionState() === 'connected');
  public focusedCore = computed(() =>
    this.emu.inspectionMode() === 'cpu1' && this.emu.cpu1Attached() ? Core.Cpu1 : Core.Cpu0
  );

  public activeLocals = computed(() =>
    this.focusedCore() === Core.Cpu1 ? this.emu.cpu1Locals() : this.emu.cpu0Locals()
  );

  public activeSourceBadge = computed(() => {
    const sl = this.focusedCore() === Core.Cpu1 ? this.emu.cpu1SourceLine() : this.emu.cpu0SourceLine();
    if (!sl || !sl.found || !sl.path) return '';
    const base = sl.path.split(/[\\/]/).pop() ?? sl.path;
    return `${base}:${sl.line}`;
  });

  public breakpoints = this.emu.allBreakpoints;
  public watchpoints = this.emu.watchpoints;

  public async quickAddBreak(): Promise<void> {
    const raw = this.quickTarget().trim();
    if (!raw) return;
    const core = this.focusedCore();
    if (/^0x[0-9a-f]+$/i.test(raw)) {
      const addr = parseInt(raw.slice(2), 16) >>> 0;
      await this.emu.toggleBreakpoint(addr, core);
    } else {
      await this.emu.addNamedBreakpoint(raw, core);
    }
    this.quickTarget.set('');
  }

  public async quickAddWatch(): Promise<void> {
    const raw = this.quickTarget().trim();
    if (!raw) return;
    const core = this.focusedCore();
    let addr = NaN;
    if (/^0x[0-9a-f]+$/i.test(raw) || /^[0-9a-f]{8}$/i.test(raw)) {
      addr = parseInt(raw.replace(/^0x/i, ''), 16);
    } else {
      const syms = core === Core.Cpu1 ? this.emu.cpu1ElfSymbols() : this.emu.cpu0ElfSymbols();
      const found = syms.find((s) => s.name === raw);
      if (found) addr = found.address;
    }
    if (!isNaN(addr)) {
      await this.emu.addWatchpoint(addr >>> 0, 4, Access.Write, core);
      this.quickTarget.set('');
    } else {
      this.emu.errorMessage.set(`Enter a hex address (e.g. 0x22000100) or known global symbol to watch`);
    }
  }

  public removeBp(bp: BreakpointEntry): void {
    void this.emu.removeBreakpointEntry(bp);
  }

  public removeWp(wp: WatchpointEntry): void {
    void this.emu.removeWatchpoint(wp);
  }

  public jumpMem(addr: number): void {
    this.emu.jumpMemoryTo(addr);
  }

  public accessLabel(access: Access): string {
    if (access === Access.Write) return 'W';
    if (access === Access.Read) return 'R';
    return 'RW';
  }

  public toHex8(val: number): string {
    return (val >>> 0).toString(16).padStart(8, '0');
  }
}
