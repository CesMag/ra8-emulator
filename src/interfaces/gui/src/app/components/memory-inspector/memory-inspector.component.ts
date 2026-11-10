import { Component, inject, signal, effect, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { EmulatorService } from '../../services/emulator.service';

interface MemoryRow {
  address: number;
  addressHex: string;
  bytes: number[];
  hexBytes: string[];
  changedMask: boolean[];
  rowChanged: boolean;
  ascii: string;
}

@Component({
  selector: 'app-memory-inspector',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="memory-pane">
      <!-- Sub-Toolbar -->
      <div class="memory-subtoolbar">
        <div class="sub-left">
          <span class="range-pill font-mono">0x{{ toHex8(currentBaseAddress()) }}</span>
          <span *ngIf="changedByteCount() > 0" class="delta-pill font-mono">
            Δ {{ changedByteCount() }}B mutated
          </span>
          <div class="preset-group">
            <button type="button" class="preset-btn" (click)="jumpToSram()" title="RA8 System SRAM (0x22000000)">SRAM</button>
            <button type="button" class="preset-btn" (click)="jumpToMram()" title="RA8 Code MRAM/Flash (0x02000000)">MRAM</button>
            <button type="button" class="preset-btn" (click)="jumpToSp()" title="Jump to active Stack Pointer">SP</button>
            <button type="button" class="preset-btn" (click)="jumpToPc()" title="Jump to Program Counter">PC</button>
          </div>
        </div>

        <div class="sub-right">
          <div class="addr-box">
            <input
              type="text"
              class="addr-input font-mono"
              placeholder="0x22000000"
              [ngModel]="targetAddressInput()"
              (ngModelChange)="targetAddressInput.set($event)"
              (keydown.enter)="applyAddressInput()"
            />
            <button type="button" class="nav-btn" (click)="prevPage()" title="Previous 256 bytes">◀</button>
            <button type="button" class="nav-btn" (click)="nextPage()" title="Next 256 bytes">▶</button>
          </div>
        </div>
      </div>

      <!-- Hex Table View -->
      <div class="hex-scroll">
        <div *ngIf="rows().length === 0" class="empty-state">
          Connect emulator backend or jump to mapped memory (0x22000000 SRAM, 0x02000000 MRAM)
        </div>

        <table *ngIf="rows().length > 0" class="hex-table font-mono">
          <thead>
            <tr>
              <th class="col-addr">Address</th>
              <th class="col-bytes">00 01 02 03 04 05 06 07  08 09 0A 0B 0C 0D 0E 0F</th>
              <th class="col-ascii">ASCII</th>
            </tr>
          </thead>
          <tbody>
            <tr
              *ngFor="let row of rows()"
              class="hex-row"
              [class.row-delta]="row.rowChanged"
            >
              <td class="col-addr">0x{{ row.addressHex }}</td>
              <td class="col-bytes">
                <span
                  *ngFor="let b of row.bytes; let idx = index"
                  class="byte-val"
                  [class.gap]="idx === 7"
                  [class.zero]="b === 0 && !row.changedMask[idx]"
                  [class.changed]="row.changedMask[idx]"
                  (click)="startEdit(row.address + idx, b)"
                  [title]="'Click to poke byte at 0x' + toHex8(row.address + idx)"
                >{{ row.hexBytes[idx] }}</span>
              </td>
              <td class="col-ascii">{{ row.ascii }}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <!-- Inline Poke Byte Strip -->
      <div *ngIf="editingAddr() !== null" class="edit-strip font-mono">
        <span class="edit-label">Poke byte &#64; 0x{{ toHex8(editingAddr()!) }}:</span>
        <input
          type="text"
          class="byte-input font-mono"
          [ngModel]="editByteHex()"
          (ngModelChange)="editByteHex.set($event)"
          maxlength="2"
          (keydown.enter)="saveByteEdit()"
          (keydown.escape)="cancelByteEdit()"
          autofocus
        />
        <button type="button" class="edit-action-btn write" (click)="saveByteEdit()">Write</button>
        <button type="button" class="edit-action-btn cancel" (click)="cancelByteEdit()">Cancel</button>
      </div>
    </div>
  `,
  styles: [`
    .memory-pane {
      height: 100%;
      display: flex;
      flex-direction: column;
      overflow: hidden;
      background: var(--bg-surface);
    }

    .memory-subtoolbar {
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

    .range-pill {
      font-size: 10px;
      color: var(--accent-blue);
      background: var(--accent-blue-subtle);
      padding: 1px 6px;
      border-radius: var(--radius-sm);
    }

    .delta-pill {
      font-size: 10px;
      color: var(--accent-amber);
      background: var(--accent-amber-subtle);
      padding: 1px 6px;
      border-radius: var(--radius-sm);
    }

    .preset-group {
      display: inline-flex;
      gap: 2px;
    }

    .preset-btn {
      background: transparent;
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      color: var(--text-secondary);
      font-size: 10px;
      font-weight: 500;
      padding: 1px 5px;
      cursor: pointer;
      transition: all 0.12s;
    }

    .preset-btn:hover {
      background: var(--bg-well);
      color: var(--text-primary);
    }

    .addr-box {
      display: inline-flex;
      align-items: center;
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      overflow: hidden;
    }

    .addr-input {
      background: transparent;
      border: none;
      color: var(--text-primary);
      font-size: 10px;
      padding: 2px 6px;
      width: 84px;
      outline: none;
    }

    .nav-btn {
      background: var(--border-subtle);
      border: none;
      color: var(--text-primary);
      font-size: 9px;
      padding: 2px 6px;
      cursor: pointer;
    }

    .nav-btn:hover {
      background: var(--border-strong);
    }

    .hex-scroll {
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
    }

    .hex-table {
      width: 100%;
      border-collapse: collapse;
      table-layout: fixed;
    }

    .hex-table th {
      background: var(--bg-well);
      color: var(--text-tertiary);
      font-weight: 600;
      padding: 3px 6px;
      text-align: left;
      font-size: 10px;
      position: sticky;
      top: 0;
      z-index: 2;
      border-bottom: 1px solid var(--border-subtle);
    }

    .hex-row {
      border-bottom: 1px solid var(--border-subtle);
      height: 19px;
    }

    .hex-row:hover {
      background: var(--bg-well);
    }

    .hex-row.row-delta {
      background: var(--accent-amber-subtle);
    }

    .col-addr {
      color: var(--text-secondary);
      padding: 0 6px;
      width: 82px;
    }

    .col-bytes {
      padding: 0 4px;
      white-space: nowrap;
    }

    .byte-val {
      display: inline-block;
      width: 20px;
      text-align: center;
      color: var(--text-primary);
      cursor: pointer;
      border-radius: 2px;
      transition: background 0.1s;
    }

    .byte-val:hover {
      background: var(--accent-blue);
      color: #ffffff;
    }

    .byte-val.gap {
      margin-right: 6px;
    }

    .byte-val.zero {
      color: var(--text-tertiary);
    }

    .byte-val.changed {
      color: var(--accent-amber);
      font-weight: 700;
      background: var(--accent-amber-subtle);
    }

    .col-ascii {
      color: var(--accent-blue);
      padding: 0 6px;
      border-left: 1px solid var(--border-subtle);
      white-space: pre;
    }

    .edit-strip {
      height: 26px;
      min-height: 26px;
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 0 10px;
      background: var(--bg-well);
      border-top: 1px solid var(--border-subtle);
      font-size: 10px;
      flex-shrink: 0;
    }

    .edit-label {
      color: var(--text-secondary);
    }

    .byte-input {
      width: 30px;
      background: var(--bg-surface);
      border: 1px solid var(--accent-amber);
      color: var(--accent-amber);
      font-size: 10px;
      padding: 1px 4px;
      text-align: center;
      border-radius: var(--radius-sm);
      outline: none;
    }

    .edit-action-btn {
      padding: 1px 6px;
      border-radius: var(--radius-sm);
      font-size: 10px;
      font-weight: 500;
      border: none;
      cursor: pointer;
    }

    .edit-action-btn.write {
      background: var(--accent-blue);
      color: #ffffff;
    }

    .edit-action-btn.cancel {
      background: var(--border-subtle);
      color: var(--text-secondary);
    }
  `]
})
export class MemoryInspectorComponent {
  private emu = inject(EmulatorService);

  public currentBaseAddress = signal<number>(0x02000000); // Default RA8 Code MRAM base
  public targetAddressInput = signal<string>('0x02000000');
  public rows = signal<MemoryRow[]>([]);
  public changedByteCount = signal<number>(0);
  public editingAddr = signal<number | null>(null);
  public editByteHex = signal<string>('00');

  private previousPageAddr: number | null = null;
  private previousBytes: Uint8Array | null = null;
  private readonly PAGE_SIZE = 256;

  constructor() {
    effect(() => {
      const state = this.emu.connectionState();
      const addr = this.currentBaseAddress();
      const _epoch = this.emu.memoryEpoch();
      if (state === 'connected') {
        void this.fetchMemory(addr, _epoch >= 0);
      } else {
        this.rows.set([]);
        this.changedByteCount.set(0);
        this.previousBytes = null;
      }
    });
  }

  public jumpTo(addr: number): void {
    const aligned = (addr & ~0xf) >>> 0;
    this.currentBaseAddress.set(aligned);
    this.targetAddressInput.set(`0x${this.toHex8(aligned)}`);
  }

  public jumpToSram(): void {
    this.jumpTo(0x22000000);
  }

  public jumpToMram(): void {
    this.jumpTo(0x02000000);
  }

  public jumpToSp(): void {
    const sp = this.emu.cpu0Registers()['sp'] ?? 0x22000000;
    this.jumpTo(sp);
  }

  public jumpToPc(): void {
    const pc = this.emu.cpu0Pc() || 0x02000000;
    this.jumpTo(pc);
  }

  public applyAddressInput(): void {
    const raw = this.targetAddressInput().trim();
    const parsed = raw.startsWith('0x') || raw.startsWith('0X')
      ? parseInt(raw.slice(2), 16)
      : parseInt(raw, 16);
    if (!isNaN(parsed)) {
      this.jumpTo(parsed >>> 0);
    }
  }

  public prevPage(): void {
    this.jumpTo(Math.max(0, this.currentBaseAddress() - this.PAGE_SIZE));
  }

  public nextPage(): void {
    this.jumpTo((this.currentBaseAddress() + this.PAGE_SIZE) >>> 0);
  }

  public startEdit(addr: number, currentVal: number): void {
    this.editingAddr.set(addr);
    this.editByteHex.set(currentVal.toString(16).padStart(2, '0').toUpperCase());
  }

  public cancelByteEdit(): void {
    this.editingAddr.set(null);
  }

  public async saveByteEdit(): Promise<void> {
    const addr = this.editingAddr();
    if (addr === null) return;
    const val = parseInt(this.editByteHex(), 16);
    if (!isNaN(val)) {
      await this.emu.writeMemory(addr, new Uint8Array([val & 0xff]));
    }
    this.editingAddr.set(null);
  }

  private async fetchMemory(addr: number, compareDelta: boolean): Promise<void> {
    const bytes = await this.emu.readMemory(addr, this.PAGE_SIZE);
    if (!bytes) {
      this.rows.set([]);
      return;
    }

    const samePage = compareDelta && this.previousPageAddr === addr && this.previousBytes !== null;
    const prev = this.previousBytes;
    let deltaTotal = 0;

    const newRows: MemoryRow[] = [];
    for (let r = 0; r < bytes.length; r += 16) {
      const rowAddr = (addr + r) >>> 0;
      const slice = bytes.subarray(r, r + 16);
      const rowBytes: number[] = [];
      const hexBytes: string[] = [];
      const changedMask: boolean[] = [];
      let rowChanged = false;
      let ascii = '';

      for (let i = 0; i < 16; i++) {
        if (i < slice.length) {
          const b = slice[i] ?? 0;
          const isChanged = Boolean(samePage && prev && prev[r + i] !== undefined && prev[r + i] !== b);
          if (isChanged) {
            rowChanged = true;
            deltaTotal += 1;
          }
          rowBytes.push(b);
          hexBytes.push(b.toString(16).padStart(2, '0').toUpperCase());
          changedMask.push(isChanged);
          ascii += b >= 32 && b <= 126 ? String.fromCharCode(b) : '.';
        } else {
          rowBytes.push(0);
          hexBytes.push('  ');
          changedMask.push(false);
          ascii += ' ';
        }
      }

      newRows.push({
        address: rowAddr,
        addressHex: this.toHex8(rowAddr),
        bytes: rowBytes,
        hexBytes,
        changedMask,
        rowChanged,
        ascii,
      });
    }

    this.previousPageAddr = addr;
    this.previousBytes = new Uint8Array(bytes);
    this.changedByteCount.set(deltaTotal);
    this.rows.set(newRows);
  }

  public toHex8(val: number): string {
    return (val >>> 0).toString(16).padStart(8, '0');
  }
}
