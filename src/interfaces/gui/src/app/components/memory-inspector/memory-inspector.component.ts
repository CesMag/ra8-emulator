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
    <div class="pane-card">
      <div class="pane-header">
        <div class="header-left">
          <span class="pane-title">Memory Hex Inspector</span>
          <span class="range-badge">0x{{ toHex8(currentBaseAddress()) }}</span>
          <span *ngIf="changedByteCount() > 0" class="delta-badge">
            Δ {{ changedByteCount() }} bytes mutated
          </span>
        </div>
        <div class="header-right">
          <div class="preset-group">
            <button type="button" class="preset-btn" (click)="jumpToSram()" title="RA8 System SRAM (0x22000000)">SRAM</button>
            <button type="button" class="preset-btn" (click)="jumpToMram()" title="RA8 Code MRAM/Flash (0x02000000)">MRAM</button>
            <button type="button" class="preset-btn" (click)="jumpToSp()" title="Jump to active Stack Pointer">SP</button>
            <button type="button" class="preset-btn" (click)="jumpToPc()" title="Jump to Program Counter">PC</button>
          </div>

          <div class="addr-box">
            <input
              type="text"
              class="addr-input"
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

      <div class="hex-scroll">
        <div *ngIf="rows().length === 0" class="empty-state">
          Connect emulator backend or enter a mapped RA8 address (e.g. 0x22000000 SRAM, 0x02000000 MRAM)
        </div>

        <table *ngIf="rows().length > 0" class="hex-table">
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

      <div *ngIf="editingAddr() !== null" class="edit-bar">
        <span class="edit-label">Poke byte &#64; 0x{{ toHex8(editingAddr()!) }}:</span>
        <input
          type="text"
          class="byte-input"
          [ngModel]="editByteHex()"
          (ngModelChange)="editByteHex.set($event)"
          maxlength="2"
          (keydown.enter)="saveByteEdit()"
          (keydown.escape)="cancelByteEdit()"
          autofocus
        />
        <button type="button" class="edit-btn save" (click)="saveByteEdit()">Write</button>
        <button type="button" class="edit-btn cancel" (click)="cancelByteEdit()">Cancel</button>
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
      gap: 7px;
      flex-wrap: wrap;
    }

    .pane-title {
      font-size: 0.8rem;
      font-weight: 600;
      color: #f1f5f9;
    }

    .range-badge {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.68rem;
      color: #38bdf8;
      background: rgba(56, 189, 248, 0.1);
      border: 1px solid rgba(56, 189, 248, 0.22);
      padding: 1px 6px;
      border-radius: 4px;
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

    .preset-group {
      display: inline-flex;
      gap: 3px;
    }

    .preset-btn {
      background: rgba(30, 41, 59, 0.75);
      border: 1px solid rgba(255, 255, 255, 0.09);
      color: #94a3b8;
      font-size: 0.65rem;
      font-weight: 600;
      padding: 2px 7px;
      border-radius: 4px;
      cursor: pointer;
    }
    .preset-btn:hover { color: #f8fafc; background: rgba(51, 65, 85, 0.9); }

    .addr-box {
      display: inline-flex;
      align-items: center;
      background: #090d16;
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 5px;
      overflow: hidden;
    }

    .addr-input {
      background: transparent;
      border: none;
      color: #f1f5f9;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.7rem;
      padding: 3px 7px;
      width: 92px;
      outline: none;
    }

    .nav-btn {
      background: rgba(51, 65, 85, 0.8);
      border: none;
      color: #e2e8f0;
      font-size: 0.65rem;
      padding: 3px 7px;
      cursor: pointer;
    }
    .nav-btn:hover { background: #475569; }

    .hex-scroll {
      max-height: 245px;
      overflow-y: auto;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.71rem;
    }

    .empty-state {
      padding: 22px 14px;
      text-align: center;
      color: #64748b;
      font-size: 0.71rem;
    }

    .hex-table {
      width: 100%;
      border-collapse: collapse;
    }

    .hex-table th {
      background: rgba(9, 13, 22, 0.92);
      color: #64748b;
      font-weight: 600;
      padding: 4px 8px;
      text-align: left;
      font-size: 0.66rem;
      position: sticky;
      top: 0;
      z-index: 2;
    }

    .hex-row {
      border-bottom: 1px solid rgba(255, 255, 255, 0.035);
    }
    .hex-row:hover { background: rgba(30, 41, 59, 0.4); }
    .hex-row.row-delta {
      background: rgba(245, 158, 11, 0.05);
    }

    .col-addr {
      color: #94a3b8;
      padding: 2px 8px;
      width: 88px;
    }

    .col-bytes {
      padding: 2px 6px;
      white-space: nowrap;
    }

    .byte-val {
      display: inline-block;
      width: 21px;
      text-align: center;
      color: #e2e8f0;
      cursor: pointer;
      border-radius: 3px;
    }
    .byte-val:hover {
      background: #38bdf8;
      color: #020617;
    }
    .byte-val.gap { margin-right: 7px; }
    .byte-val.zero { color: #475569; }
    .byte-val.changed {
      color: #fbbf24;
      font-weight: 700;
      background: rgba(245, 158, 11, 0.2);
      box-shadow: 0 0 6px rgba(245, 158, 11, 0.25);
    }

    .col-ascii {
      color: #38bdf8;
      padding: 2px 8px;
      border-left: 1px solid rgba(255, 255, 255, 0.05);
      white-space: pre;
    }

    .edit-bar {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 5px 12px;
      background: rgba(15, 23, 42, 0.9);
      border-top: 1px solid rgba(255, 255, 255, 0.08);
      font-size: 0.72rem;
    }
    .edit-label { color: #cbd5e1; font-family: "JetBrains Mono", monospace; }
    .byte-input {
      width: 34px;
      background: #090d16;
      border: 1px solid #f59e0b;
      color: #fbbf24;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.72rem;
      padding: 1px 4px;
      text-align: center;
      border-radius: 4px;
      outline: none;
    }
    .edit-btn {
      padding: 2px 8px;
      border-radius: 4px;
      font-size: 0.69rem;
      font-weight: 600;
      border: none;
      cursor: pointer;
    }
    .edit-btn.save { background: #0284c7; color: #fff; }
    .edit-btn.cancel { background: #334155; color: #e2e8f0; }
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
