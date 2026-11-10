import { LocalVariable, LocalWhereKind } from 'ra8-rpc-client';

export interface EvaluatedLocal {
  name: string;
  typeName: string;
  size: number;
  locationLabel: string;
  valueHex: string;
  valueDec: string;
}

const DWARF_ARM_REG_NAMES: Record<number, string> = {
  0: 'r0',
  1: 'r1',
  2: 'r2',
  3: 'r3',
  4: 'r4',
  5: 'r5',
  6: 'r6',
  7: 'r7',
  8: 'r8',
  9: 'r9',
  10: 'r10',
  11: 'r11',
  12: 'r12',
  13: 'sp',
  14: 'lr',
  15: 'pc',
};

function formatScalarBytes(bytes: Uint8Array, size: number, typeName: string): { hex: string; dec: string } {
  const n = Math.min(bytes.length, Math.max(1, size));
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const isSigned = /^(int|short|char|long|i8|i16|i32|ssize)/i.test(typeName.trim()) && !/^u/i.test(typeName.trim());

  if (n === 1) {
    const u = view.getUint8(0);
    const s = isSigned ? view.getInt8(0) : u;
    return { hex: '0x' + u.toString(16).padStart(2, '0'), dec: String(s) };
  }
  if (n === 2 && bytes.length >= 2) {
    const u = view.getUint16(0, true);
    const s = isSigned ? view.getInt16(0, true) : u;
    return { hex: '0x' + u.toString(16).padStart(4, '0'), dec: String(s) };
  }
  if (bytes.length >= 4) {
    const u = view.getUint32(0, true) >>> 0;
    const s = isSigned ? view.getInt32(0, true) : u;
    return { hex: '0x' + u.toString(16).padStart(8, '0'), dec: String(s) };
  }
  const hex = '0x' + Array.from(bytes.subarray(0, n)).map((b) => b.toString(16).padStart(2, '0')).join('');
  return { hex, dec: '' };
}

export async function evaluateLocals(
  locals: LocalVariable[],
  regs: Record<string, number>,
  readMem: (addr: number, len: number) => Promise<Uint8Array | null>
): Promise<EvaluatedLocal[]> {
  const results: EvaluatedLocal[] = [];
  for (const loc of locals) {
    const readLen = Math.min(Math.max(loc.size || 4, 1), 8);
    if (loc.whereKind === LocalWhereKind.InRegister) {
      const regIdx = Number(loc.whereA);
      const regName = DWARF_ARM_REG_NAMES[regIdx] ?? `r${regIdx}`;
      const regVal = regs[regName];
      if (regVal !== undefined) {
        const u = regVal >>> 0;
        const s = /^(int|short|char|long|i8|i16|i32)/i.test(loc.typeName) ? (regVal | 0) : u;
        results.push({
          name: loc.name,
          typeName: loc.typeName || 'word',
          size: loc.size || 4,
          locationLabel: regName.toUpperCase(),
          valueHex: '0x' + u.toString(16).padStart(8, '0'),
          valueDec: String(s),
        });
      } else {
        results.push({
          name: loc.name,
          typeName: loc.typeName || 'reg',
          size: loc.size,
          locationLabel: regName.toUpperCase(),
          valueHex: '—',
          valueDec: '',
        });
      }
      continue;
    }

    let addr: number | null = null;
    let locLabel = 'optimized out';

    if (loc.whereKind === LocalWhereKind.Address) {
      addr = Number(loc.whereA) >>> 0;
      locLabel = `0x${addr.toString(16).padStart(8, '0')}`;
    } else if (loc.whereKind === LocalWhereKind.Frame) {
      const base = regs['sp'] ?? regs['r7'] ?? null;
      const off = Number(loc.whereA);
      locLabel = `frame${off >= 0 ? '+' : ''}${off}`;
      if (base !== null) {
        addr = (base + off) >>> 0;
      }
    } else if (loc.whereKind === LocalWhereKind.RegisterIndirect) {
      const regIdx = Number(loc.whereA);
      const regName = DWARF_ARM_REG_NAMES[regIdx] ?? `r${regIdx}`;
      const off = Number(loc.whereB);
      locLabel = `[${regName.toUpperCase()}${off >= 0 ? '+' : ''}${off}]`;
      const base = regs[regName];
      if (base !== undefined) {
        addr = (base + off) >>> 0;
      }
    }

    if (addr !== null) {
      const mem = await readMem(addr, readLen);
      if (mem && mem.length > 0) {
        const formatted = formatScalarBytes(mem, readLen, loc.typeName);
        results.push({
          name: loc.name,
          typeName: loc.typeName || `${readLen}B`,
          size: loc.size,
          locationLabel: locLabel,
          valueHex: formatted.hex,
          valueDec: formatted.dec,
        });
        continue;
      }
    }

    results.push({
      name: loc.name,
      typeName: loc.typeName || 'unknown',
      size: loc.size,
      locationLabel: locLabel,
      valueHex: '—',
      valueDec: '',
    });
  }
  return results;
}
