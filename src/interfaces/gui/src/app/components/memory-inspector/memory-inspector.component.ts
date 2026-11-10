import { Component, inject, computed, signal, effect } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { EmulatorService } from '../../services/emulator.service';

interface MemoryRow {
  address: number;
  addressHex: string;
  bytes: number[];
  hexBytes: string[];
  ascii: string;
}

@Component({
  selector: 'app-memory-inspector',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="memory-card">
      <div class="card-header">
        <div class="header-left">
          <span class="title">MEMORY INSPECTOR</span>
          <span class="range-badge">0x{{ toHex8(currentBaseAddress()) }}</span>
        </div>
        <div class="header-right">
          <!-- Preset buttons -->
          <div class="preset-group">
            <button type="button" class="preset-btn" (click)="jumpToSram()">SRAM</button>
            <button type="button" class="preset-btn" (click)="jumpToFlash()">FLASH</button>
            <button type="button" class="preset-btn" (click)="jumpToSp()">SP</button>
            <button type="button" class="preset-btn" (click)="jumpToPc()">PC</button>
          </div>

          <!-- Address navigation input -->
          <div class="addr-box">
            <input
              type="text"
              class="addr-input"
              placeholder="0x20000000"
              [ngModel]="targetAddressInput()"
              (ngModelChange)="targetAddressInput.set($event)"
              (keydown.enter)="applyAddressInput()"
            />
            <button type="button" class="nav-btn" (click)="prevPage()" title="Previous 256 bytes">◀</button>
            <button type="button" class="nav-btn" (click)="nextPage()" title="Next 256 bytes">▶</button>
          </div>
        </div>
      </div>

      <div class="hex-table-container">
        <div *ngIf="rows().length === 0" class="empty-state">
          No memory data loaded (Connect or navigate to valid address range)
        </div>

        <table *ngIf="rows().length > 0" class="hex-table">
          <thead>
            <tr>
              <th class="col-addr">Offset</th>
              <th class="col-bytes" colspan="16">
                <span>00 01 02 03 04 05 06 07  08 09 0A 0B 0C 0D 0E 0F</span>
              </th>
              <th class="col-ascii">Decoded Text</th>
            </tr>
          </thead>
          <tbody>
            <tr *ngFor="let row of rows()" class="hex-row">
              <td class="col-addr">0x{{ row.addressHex }}</td>
              <td class="col-bytes">
                <span
                  *ngFor="let b of row.bytes; let idx = index"
                  class="byte-val"
                  [class.gap]="idx === 7"
                  [class.zero]="b === 0"
                  (click)="startEdit(row.address + idx, b)"
                  [title]="'Edit byte at 0x' + toHex8(row.address + idx)"
                >
                  {{ row.hexBytes[idx] }}
                </span>
              </td>
              <td class="col-ascii">{{ row.ascii }}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <!-- Edit Byte Modal/Bar -->
      <div *ngIf="editingAddr() !== null" class="edit-bar">
        <span class="edit-label">Writing byte at 0x{{ toHex8(editingAddr()!) }}:</span>
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
    .memory-card {
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

    .range-badge {
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
      gap: 8px;
    }

    .preset-group {
      display: flex;
      gap: 2px;
    }

    .preset-btn {
      background: #1e293b;
      border: 1px solid #334155;
      color: #94a3b8;
      font-size: 0.65rem;
      padding: 2px 6px;
      border-radius: 3px;
      cursor: pointer;
    }
    .preset-btn:hover { background: #334155; color: #fff; }

    .addr-box {
      display: flex;
      align-items: center;
      border: 1px solid var(--border-color);
      border-radius: 4px;
      overflow: hidden;
    }

    .addr-input {
      background: #0f172a;
      border: none;
      color: #f1f5f9;
      font-family: monospace;
      font-size: 0.7rem;
      padding: 2px 6px;
      width: 95px;
      outline: none;
    }

    .nav-btn {
      background: #334155;
      border: none;
      color: #f1f5f9;
      font-size: 0.65rem;
      padding: 2px 6px;
      cursor: pointer;
    }
    .nav-btn:hover { background: #475569; }

    .hex-table-container {
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

    .hex-table {
      width: 100%;
      border-collapse: collapse;
      user-select: text;
    }

    .hex-table th {
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

    .hex-row {
      border-bottom: 1px solid #1c2028;
    }
    .hex-row:hover { background: #1e2430; }

    .col-addr {
      color: #94a3b8;
      padding: 2px 8px;
      width: 90px;
    }

    .col-bytes {
      padding: 2px 8px;
      letter-spacing: 0.05em;
    }

    .byte-val {
      display: inline-block;
      width: 22px;
      text-align: center;
      color: #f1f5f9;
      cursor: pointer;
      border-radius: 2px;
    }
    .byte-val:hover {
      background: #38bdf8;
      color: #000;
    }
    .byte-val.gap {
      margin-right: 8px;
    }
    .byte-val.zero {
      color: #475569;
    }

    .col-ascii {
      color: #38bdf8;
      padding: 2px 8px;
      border-left: 1px solid #1c2028;
      white-space: pre;
    }

    .edit-bar {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 4px 10px;
      background: #1e293b;
      border-top: 1px solid #334155;
      font-size: 0.75rem;
    }

    .edit-label { color: #94a3b8; font-family: monospace; }
    .byte-input {
      width: 35px;
      background: #0f172a;
      border: 1px solid #38bdf8;
      color: #38bdf8;
      font-family: monospace;
      font-size: 0.75rem;
      padding: 1px 4px;
      text-align: center;
      outline: none;
    }
    .edit-btn {
      padding: 2px 8px;
      border-radius: 3px;
      font-size: 0.7rem;
      cursor: pointer;
      border: none;
    }
    .edit-btn.save { background: #0284c7; color: #fff; }
    .edit-btn.cancel { background: #475569; color: #fff; }
  `]
})
export class MemoryInspectorComponent {
  private emu = inject(EmulatorService);

  public currentBaseAddress = signal<number>(0x20000000); // Default SRAM base
  public targetAddressInput = signal<string>('0x20000000');
  public rows = signal<MemoryRow[]>([]);
  public editingAddr = signal<number | null>(null);
  public editByteHex = signal<string>('00');

  private readonly PAGE_SIZE = 256; // 16 rows * 16 bytes

  constructor() {
    // When connection or base address changes, reload memory
    effect(() => {
      const state = this.emu.connectionState();
      const addr = this.currentBaseAddress();
      if (state === 'connected') {
        this.fetchMemory(addr);
      } else {
        this.rows.set([]);
      }
    });
  }

  public jumpTo(addr: number): void {
    this.currentBaseAddress.set(addr >>> 0);
    this.targetAddressInput.set(`0x${this.toHex8(addr)}`);
  }

  public jumpToSram(): void {
    this.jumpTo(0x20000000);
  }

  public jumpToFlash(): void {
    this.jumpTo(0x00000000);
  }

  public jumpToSp(): void {
    const sp = this.emu.registers()['sp'] ?? 0x20004000;
    this.jumpTo(sp & ~0xF);
  }

  public jumpToPc(): void {
    const pc = this.emu.registers()['pc'] ?? 0x00000000;
    this.jumpTo(pc & ~0xF);
  }

  public applyAddressInput(): void {
    const raw = this.targetAddressInput().trim();
    const parsed = raw.startsWith('0x') || raw.startsWith('0X')
      ? parseInt(raw.slice(2), 16)
      : parseInt(raw, 10);

    if (!isNaN(parsed)) {
      this.jumpTo(parsed & ~0xF);
    }
  }

  public prevPage(): void {
    const next = Math.max(0, this.currentBaseAddress() - this.PAGE_SIZE);
    this.jumpTo(next);
  }

  public nextPage(): void {
    const next = (this.currentBaseAddress() + this.PAGE_SIZE) >>> 0;
    this.jumpTo(next);
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
      const ok = await this.emu.writeMemory(addr, new Uint8Array([val & 0xFF]));
      if (ok) {
        await this.fetchMemory(this.currentBaseAddress());
      }
    }
    this.editingAddr.set(null);
  }

  private async fetchMemory(addr: number): Promise<void> {
    const bytes = await this.emu.readMemory(addr, this.PAGE_SIZE);
    if (!bytes) {
      this.rows.set([]);
      return;
    }

    const newRows: MemoryRow[] = [];
    for (let r = 0; r < bytes.length; r += 16) {
      const rowAddr = (addr + r) >>> 0;
      const slice = bytes.subarray(r, r + 16);
      const rowBytes: number[] = [];
      const hexBytes: string[] = [];
      let ascii = '';

      for (let i = 0; i < 16; i++) {
        if (i < slice.length) {
          const b = slice[i];
          rowBytes.push(b);
          hexBytes.push(b.toString(16).padStart(2, '0').toUpperCase());
          ascii += (b >= 32 && b <= 126) ? String.fromCharCode(b) : '.';
        } else {
          rowBytes.push(0);
          hexBytes.push('??');
          ascii += ' ';
        }
      }

      newRows.push({
        address: rowAddr,
        addressHex: this.toHex8(rowAddr),
        bytes: rowBytes,
        hexBytes,
        ascii
      });
    }

    this.rows.set(newRows);
  }

  public toHex8(val: number): string {
    return (val >>> 0).toString(16).padStart(8, '0');
  }
}
