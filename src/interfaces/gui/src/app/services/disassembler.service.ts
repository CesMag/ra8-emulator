import { Injectable } from '@angular/core';

export interface DecodedInstruction {
  address: number;
  hex: string;
  mnemonic: string;
  operands: string;
  is32Bit: boolean;
  isCurrentPc: boolean;
  hasBreakpoint: boolean;
}

@Injectable({
  providedIn: 'root'
})
export class DisassemblerService {
  /**
   * Disassemble a buffer of bytes at a base address.
   */
  public disassemble(
    bytes: Uint8Array,
    baseAddress: number,
    currentPc: number,
    breakpoints: Set<number>
  ): DecodedInstruction[] {
    const instructions: DecodedInstruction[] = [];
    const len = bytes.length;
    let offset = 0;

    while (offset + 1 < len) {
      const addr = (baseAddress + offset) >>> 0;
      const hw1 = bytes[offset] | (bytes[offset + 1] << 8);

      // Check for 32-bit Thumb-2 instruction
      const is32 = (hw1 & 0xF800) === 0xF000 || (hw1 & 0xF800) === 0xF800 || (hw1 & 0xE800) === 0xE800;

      if (is32 && offset + 3 < len) {
        const hw2 = bytes[offset + 2] | (bytes[offset + 3] << 8);
        const hex = `${this.toHex16(hw1)} ${this.toHex16(hw2)}`;
        const { mnemonic, operands } = this.decodeThumb32(hw1, hw2, addr);
        instructions.push({
          address: addr,
          hex,
          mnemonic,
          operands,
          is32Bit: true,
          isCurrentPc: (addr & ~1) === (currentPc & ~1),
          hasBreakpoint: breakpoints.has(addr) || breakpoints.has(addr & ~1)
        });
        offset += 4;
      } else {
        const hex = this.toHex16(hw1);
        const { mnemonic, operands } = this.decodeThumb16(hw1, addr);
        instructions.push({
          address: addr,
          hex,
          mnemonic,
          operands,
          is32Bit: false,
          isCurrentPc: (addr & ~1) === (currentPc & ~1),
          hasBreakpoint: breakpoints.has(addr) || breakpoints.has(addr & ~1)
        });
        offset += 2;
      }
    }

    return instructions;
  }

  private decodeThumb16(hw: number, pc: number): { mnemonic: string; operands: string } {
    const regNames = ['r0', 'r1', 'r2', 'r3', 'r4', 'r5', 'r6', 'r7', 'r8', 'r9', 'r10', 'r11', 'r12', 'sp', 'lr', 'pc'];

    // NOP / hints
    if (hw === 0xBF00) return { mnemonic: 'nop', operands: '' };
    if (hw === 0xBF10) return { mnemonic: 'yield', operands: '' };
    if (hw === 0xBF20) return { mnemonic: 'wfe', operands: '' };
    if (hw === 0xBF30) return { mnemonic: 'wfi', operands: '' };
    if (hw === 0xBF40) return { mnemonic: 'sev', operands: '' };

    // BKPT
    if ((hw & 0xFF00) === 0xBE00) {
      return { mnemonic: 'bkpt', operands: `0x${(hw & 0xFF).toString(16)}` };
    }

    // SVC
    if ((hw & 0xFF00) === 0xDF00) {
      return { mnemonic: 'svc', operands: `0x${(hw & 0xFF).toString(16)}` };
    }

    // Shift (immediate), add, subtract, move, and compare
    const opTop = hw >> 11;

    // Shift immediate: LSL, LSR, ASR
    if (opTop === 0) { // LSLS Rd, Rm, #imm5
      const imm5 = (hw >> 6) & 0x1F;
      const rm = regNames[(hw >> 3) & 0x7];
      const rd = regNames[hw & 0x7];
      if (imm5 === 0) return { mnemonic: 'movs', operands: `${rd}, ${rm}` };
      return { mnemonic: 'lsls', operands: `${rd}, ${rm}, #${imm5}` };
    }
    if (opTop === 1) { // LSRS Rd, Rm, #imm5
      const imm5 = (hw >> 6) & 0x1F;
      const rm = regNames[(hw >> 3) & 0x7];
      const rd = regNames[hw & 0x7];
      return { mnemonic: 'lsrs', operands: `${rd}, ${rm}, #${imm5 || 32}` };
    }
    if (opTop === 2) { // ASRS Rd, Rm, #imm5
      const imm5 = (hw >> 6) & 0x1F;
      const rm = regNames[(hw >> 3) & 0x7];
      const rd = regNames[hw & 0x7];
      return { mnemonic: 'asrs', operands: `${rd}, ${rm}, #${imm5 || 32}` };
    }

    // Add / subtract (register and immediate 3-bit)
    if ((hw & 0xF800) === 0x1800) {
      const op = (hw >> 9) & 0x3;
      const rnOrImm = (hw >> 6) & 0x7;
      const rm = regNames[(hw >> 3) & 0x7];
      const rd = regNames[hw & 0x7];
      if (op === 0) return { mnemonic: 'adds', operands: `${rd}, ${rm}, ${regNames[rnOrImm]}` };
      if (op === 1) return { mnemonic: 'subs', operands: `${rd}, ${rm}, ${regNames[rnOrImm]}` };
      if (op === 2) return { mnemonic: 'adds', operands: `${rd}, ${rm}, #${rnOrImm}` };
      if (op === 3) return { mnemonic: 'subs', operands: `${rd}, ${rm}, #${rnOrImm}` };
    }

    // Move, compare, add, subtract immediate 8-bit
    if (opTop === 4) { // MOVS Rd, #imm8
      const rd = regNames[(hw >> 8) & 0x7];
      return { mnemonic: 'movs', operands: `${rd}, #${hw & 0xFF}` };
    }
    if (opTop === 5) { // CMP Rd, #imm8
      const rd = regNames[(hw >> 8) & 0x7];
      return { mnemonic: 'cmp', operands: `${rd}, #${hw & 0xFF}` };
    }
    if (opTop === 6) { // ADDS Rd, #imm8
      const rd = regNames[(hw >> 8) & 0x7];
      return { mnemonic: 'adds', operands: `${rd}, #${hw & 0xFF}` };
    }
    if (opTop === 7) { // SUBS Rd, #imm8
      const rd = regNames[(hw >> 8) & 0x7];
      return { mnemonic: 'subs', operands: `${rd}, #${hw & 0xFF}` };
    }

    // Data-processing register
    if ((hw & 0xFC00) === 0x4000) {
      const op = (hw >> 6) & 0xF;
      const rm = regNames[(hw >> 3) & 0x7];
      const rdn = regNames[hw & 0x7];
      const ops = [
        'ands', 'eors', 'lsls', 'lsrs', 'asrs', 'adcs', 'sbcs', 'rors',
        'tst', 'rsbs', 'cmp', 'cmn', 'orrs', 'muls', 'bics', 'mvns'
      ];
      return { mnemonic: ops[op] || 'dp', operands: `${rdn}, ${rm}` };
    }

    // Special data and branch exchange (high registers)
    if ((hw & 0xFC00) === 0x4400) {
      const op = (hw >> 8) & 0x3;
      const rm = regNames[(hw >> 3) & 0xF];
      const rdn = regNames[((hw >> 4) & 0x8) | (hw & 0x7)];
      if (op === 0) return { mnemonic: 'add', operands: `${rdn}, ${rm}` };
      if (op === 1) return { mnemonic: 'cmp', operands: `${rdn}, ${rm}` };
      if (op === 2) return { mnemonic: 'mov', operands: `${rdn}, ${rm}` };
      if (op === 3) {
        if ((hw & 0x80) === 0) return { mnemonic: 'bx', operands: rm };
        return { mnemonic: 'blx', operands: rm };
      }
    }

    // LDR (literal): LDR Rt, [PC, #imm8]
    if ((hw & 0xF800) === 0x4800) {
      const rt = regNames[(hw >> 8) & 0x7];
      const imm = (hw & 0xFF) << 2;
      const target = ((pc + 4) & ~3) + imm;
      return { mnemonic: 'ldr', operands: `${rt}, [pc, #${imm}] ; 0x${target.toString(16)}` };
    }

    // Load/store single data item
    // STR, STRH, STRB, LDRSB, LDR, LDRH, LDRB, LDRSH (register offset)
    if ((hw & 0xF200) === 0x5000) {
      const op = (hw >> 9) & 0x7;
      const rm = regNames[(hw >> 6) & 0x7];
      const rn = regNames[(hw >> 3) & 0x7];
      const rt = regNames[hw & 0x7];
      const names = ['str', 'strh', 'strb', 'ldrsb', 'ldr', 'ldrh', 'ldrb', 'ldrsh'];
      return { mnemonic: names[op], operands: `${rt}, [${rn}, ${rm}]` };
    }

    // STR/LDR immediate offset 5-bit
    if ((hw & 0xE000) === 0x6000) {
      const isLdr = (hw & 0x0800) !== 0;
      const isByte = (hw & 0x1000) !== 0;
      const imm = ((hw >> 6) & 0x1F) << (isByte ? 0 : 2);
      const rn = regNames[(hw >> 3) & 0x7];
      const rt = regNames[hw & 0x7];
      const mnem = isLdr ? (isByte ? 'ldrb' : 'ldr') : (isByte ? 'strb' : 'str');
      return { mnemonic: mnem, operands: `${rt}, [${rn}, #${imm}]` };
    }

    // STRH/LDRH immediate
    if ((hw & 0xF000) === 0x8000) {
      const isLdr = (hw & 0x0800) !== 0;
      const imm = ((hw >> 6) & 0x1F) << 1;
      const rn = regNames[(hw >> 3) & 0x7];
      const rt = regNames[hw & 0x7];
      return { mnemonic: isLdr ? 'ldrh' : 'strh', operands: `${rt}, [${rn}, #${imm}]` };
    }

    // STR/LDR SP-relative
    if ((hw & 0xF000) === 0x9000) {
      const isLdr = (hw & 0x0800) !== 0;
      const rt = regNames[(hw >> 8) & 0x7];
      const imm = (hw & 0xFF) << 2;
      return { mnemonic: isLdr ? 'ldr' : 'str', operands: `${rt}, [sp, #${imm}]` };
    }

    // ADR Rd, PC, #imm8
    if ((hw & 0xF800) === 0xA000) {
      const rd = regNames[(hw >> 8) & 0x7];
      const imm = (hw & 0xFF) << 2;
      const target = ((pc + 4) & ~3) + imm;
      return { mnemonic: 'adr', operands: `${rd}, 0x${target.toString(16)}` };
    }

    // ADD Rd, SP, #imm8
    if ((hw & 0xF800) === 0xA800) {
      const rd = regNames[(hw >> 8) & 0x7];
      const imm = (hw & 0xFF) << 2;
      return { mnemonic: 'add', operands: `${rd}, sp, #${imm}` };
    }

    // Miscellaneous 16-bit instructions (0xB000 - 0xBFFF)
    // ADD / SUB SP, #imm7
    if ((hw & 0xFF00) === 0xB000) {
      const isSub = (hw & 0x80) !== 0;
      const imm = (hw & 0x7F) << 2;
      return { mnemonic: isSub ? 'sub' : 'add', operands: `sp, sp, #${imm}` };
    }

    // CBZ / CBNZ
    if ((hw & 0xF500) === 0xB100) {
      const isCbnz = (hw & 0x0800) !== 0;
      const rn = regNames[hw & 0x7];
      const imm = (((hw >> 9) & 0x1) << 6) | (((hw >> 3) & 0x1F) << 1);
      const target = (pc + 4 + imm) >>> 0;
      return { mnemonic: isCbnz ? 'cbnz' : 'cbz', operands: `${rn}, 0x${target.toString(16)}` };
    }

    // PUSH / POP
    if ((hw & 0xF600) === 0xB400) {
      const isPop = (hw & 0x0800) !== 0;
      const rBit = (hw & 0x0100) !== 0;
      const regs: string[] = [];
      for (let i = 0; i < 8; i++) {
        if ((hw & (1 << i)) !== 0) regs.push(regNames[i]);
      }
      if (rBit) regs.push(isPop ? 'pc' : 'lr');
      return { mnemonic: isPop ? 'pop' : 'push', operands: `{${regs.join(', ')}}` };
    }

    // Conditional branch: B<c> <label>
    if ((hw & 0xF000) === 0xD000) {
      const cond = (hw >> 8) & 0xF;
      if (cond < 14) {
        const condNames = ['eq', 'ne', 'cs', 'cc', 'mi', 'pl', 'vs', 'vc', 'hi', 'ls', 'ge', 'lt', 'gt', 'le'];
        let imm8 = hw & 0xFF;
        if (imm8 & 0x80) imm8 -= 256; // sign extend
        const target = (pc + 4 + (imm8 << 1)) >>> 0;
        return { mnemonic: `b${condNames[cond]}`, operands: `0x${target.toString(16)}` };
      }
    }

    // Unconditional branch: B <label>
    if ((hw & 0xF800) === 0xE000) {
      let imm11 = hw & 0x7FF;
      if (imm11 & 0x400) imm11 -= 2048; // sign extend
      const target = (pc + 4 + (imm11 << 1)) >>> 0;
      return { mnemonic: 'b', operands: `0x${target.toString(16)}` };
    }

    return { mnemonic: '.hword', operands: `0x${this.toHex16(hw)}` };
  }

  private decodeThumb32(hw1: number, hw2: number, pc: number): { mnemonic: string; operands: string } {
    // BL / BLX (immediate)
    if ((hw1 & 0xF800) === 0xF000 && (hw2 & 0xD000) === 0xD000) {
      const s = (hw1 >> 10) & 1;
      const imm10 = hw1 & 0x3FF;
      const j1 = (hw2 >> 13) & 1;
      const j2 = (hw2 >> 11) & 1;
      const imm11 = hw2 & 0x7FF;

      const i1 = ~(j1 ^ s) & 1;
      const i2 = ~(j2 ^ s) & 1;
      let offset = (s << 24) | (i1 << 23) | (i2 << 22) | (imm10 << 12) | (imm11 << 1);
      if (s) offset -= (1 << 25); // sign extend

      const target = (pc + 4 + offset) >>> 0;
      const isBlx = (hw2 & 0x1000) === 0;
      return { mnemonic: isBlx ? 'blx' : 'bl', operands: `0x${target.toString(16)}` };
    }

    // DMB, DSB, ISB
    if (hw1 === 0xF3BF && (hw2 & 0xFFF0) === 0x8F40) return { mnemonic: 'dsb', operands: '' };
    if (hw1 === 0xF3BF && (hw2 & 0xFFF0) === 0x8F50) return { mnemonic: 'dmb', operands: '' };
    if (hw1 === 0xF3BF && (hw2 & 0xFFF0) === 0x8F60) return { mnemonic: 'isb', operands: '' };

    // MRS / MSR
    if ((hw1 & 0xFFF0) === 0xF3E0 && (hw2 & 0xFF00) === 0x8000) {
      const rd = (hw2 >> 8) & 0xF;
      const sysm = hw2 & 0xFF;
      return { mnemonic: 'mrs', operands: `r${rd}, sys(0x${sysm.toString(16)})` };
    }
    if ((hw1 & 0xFFF0) === 0xF380 && (hw2 & 0xFF00) === 0x8800) {
      const rn = hw1 & 0xF;
      const sysm = hw2 & 0xFF;
      return { mnemonic: 'msr', operands: `sys(0x${sysm.toString(16)}), r${rn}` };
    }

    // MOVT / MOVW
    if ((hw1 & 0xFBF0) === 0xF240) {
      const isMovt = (hw1 & 0x0400) !== 0;
      const imm4 = hw1 & 0xF;
      const i = (hw1 >> 10) & 1;
      const imm3 = (hw2 >> 12) & 7;
      const rd = (hw2 >> 8) & 0xF;
      const imm8 = hw2 & 0xFF;
      const val = (imm4 << 12) | (i << 11) | (imm3 << 8) | imm8;
      return { mnemonic: isMovt ? 'movt' : 'movw', operands: `r${rd}, #0x${val.toString(16)}` };
    }

    return { mnemonic: '.word', operands: `0x${this.toHex16(hw1)}${this.toHex16(hw2)}` };
  }

  private toHex16(val: number): string {
    return (val & 0xFFFF).toString(16).padStart(4, '0');
  }
}
