/**
 * Lightweight ARM ELF32 Inspector & IEEE CRC32 Calculator
 *
 * Zero-dependency browser/Node helper for validating 32-bit ARM ELF images,
 * computing CRC32 checksums for RA8 chunked RPC uploads (LoadBegin), and
 * extracting .symtab functions/globals + DWARF presence for instant UI search.
 */
const CRC32_TABLE = (() => {
    const table = new Uint32Array(256);
    for (let i = 0; i < 256; i++) {
        let c = i;
        for (let k = 0; k < 8; k++) {
            c = (c & 1) !== 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
        }
        table[i] = c >>> 0;
    }
    return table;
})();
/** Standard IEEE 802.3 CRC32 matching Zig `std.hash.Crc32.hash` */
export function crc32(bytes) {
    let crc = 0xffffffff;
    for (let i = 0; i < bytes.length; i++) {
        const idx = (crc ^ (bytes[i] ?? 0)) & 0xff;
        crc = (CRC32_TABLE[idx] ^ (crc >>> 8)) >>> 0;
    }
    return (crc ^ 0xffffffff) >>> 0;
}
/** Validate that a buffer is a 32-bit Little-Endian ARM ELF executable */
export function inspectElf(bytes) {
    if (bytes.length < 52) {
        return { valid: false, entry: 0, machine: 0, hasDebugInfo: false, reason: "File is smaller than an ELF32 header (52 bytes)" };
    }
    if (bytes[0] !== 0x7f || bytes[1] !== 0x45 || bytes[2] !== 0x4c || bytes[3] !== 0x46) {
        return { valid: false, entry: 0, machine: 0, hasDebugInfo: false, reason: "Missing ELF magic header (0x7F 'E' 'L' 'F')" };
    }
    if (bytes[4] !== 1) {
        return { valid: false, entry: 0, machine: 0, hasDebugInfo: false, reason: "Expected 32-bit ARM ELF (found 64-bit ELFCLASS64)" };
    }
    if (bytes[5] !== 1) {
        return { valid: false, entry: 0, machine: 0, hasDebugInfo: false, reason: "Expected little-endian ELFDATA2LSB encoding" };
    }
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const machine = view.getUint16(18, true);
    const entry = view.getUint32(24, true);
    if (machine !== 40) {
        return {
            valid: false,
            entry,
            machine,
            hasDebugInfo: false,
            reason: `Expected ARM architecture (EM_ARM = 40), got machine ${machine}`,
        };
    }
    return {
        valid: true,
        entry: entry >>> 0,
        machine,
        hasDebugInfo: detectDebugSections(bytes, view),
    };
}
function readNullTermString(bytes, strTabOffset, strTabSize, nameIdx) {
    if (nameIdx >= strTabSize || strTabOffset + strTabSize > bytes.length)
        return "";
    const start = strTabOffset + nameIdx;
    const maxEnd = strTabOffset + strTabSize;
    let end = start;
    while (end < maxEnd && bytes[end] !== 0) {
        end++;
    }
    if (end <= start)
        return "";
    return new TextDecoder().decode(bytes.subarray(start, end));
}
function detectDebugSections(bytes, view) {
    const shoff = view.getUint32(32, true);
    const shentsize = view.getUint16(46, true);
    const shnum = view.getUint16(48, true);
    const shstrndx = view.getUint16(50, true);
    if (shoff === 0 || shentsize < 40 || shnum === 0 || shstrndx >= shnum)
        return false;
    if (shoff + shnum * shentsize > bytes.length)
        return false;
    const shstrBase = shoff + shstrndx * shentsize;
    const shstrOffset = view.getUint32(shstrBase + 16, true);
    const shstrSize = view.getUint32(shstrBase + 20, true);
    for (let i = 0; i < shnum; i++) {
        const base = shoff + i * shentsize;
        const nameOff = view.getUint32(base, true);
        const secName = readNullTermString(bytes, shstrOffset, shstrSize, nameOff);
        if (secName === ".debug_line" || secName === ".debug_info") {
            return true;
        }
    }
    return false;
}
/** Extract function and global object symbols from an ARM ELF32 binary */
export function parseElfSymbols(bytes, maxSymbols = 2000) {
    const header = inspectElf(bytes);
    if (!header.valid)
        return [];
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const shoff = view.getUint32(32, true);
    const shentsize = view.getUint16(46, true);
    const shnum = view.getUint16(48, true);
    if (shoff === 0 || shentsize < 40 || shnum === 0)
        return [];
    if (shoff + shnum * shentsize > bytes.length)
        return [];
    const results = [];
    const seen = new Set();
    for (let s = 0; s < shnum; s++) {
        const shBase = shoff + s * shentsize;
        const shType = view.getUint32(shBase + 4, true);
        // SHT_SYMTAB = 2, SHT_DYNSYM = 11
        if (shType !== 2 && shType !== 11)
            continue;
        const symOffset = view.getUint32(shBase + 16, true);
        const symSize = view.getUint32(shBase + 20, true);
        const strSectionIdx = view.getUint32(shBase + 24, true);
        const entsize = view.getUint32(shBase + 36, true) || 16;
        if (strSectionIdx >= shnum || entsize < 16)
            continue;
        if (symOffset + symSize > bytes.length)
            continue;
        const strShBase = shoff + strSectionIdx * shentsize;
        const strOffset = view.getUint32(strShBase + 16, true);
        const strSize = view.getUint32(strShBase + 20, true);
        if (strOffset + strSize > bytes.length)
            continue;
        const count = Math.floor(symSize / entsize);
        for (let i = 0; i < count; i++) {
            const symBase = symOffset + i * entsize;
            const stName = view.getUint32(symBase, true);
            const stValue = view.getUint32(symBase + 4, true);
            const stSize = view.getUint32(symBase + 8, true);
            const stInfo = bytes[symBase + 12] ?? 0;
            const stShndx = view.getUint16(symBase + 14, true);
            if (stName === 0 || stShndx === 0 || stValue === 0)
                continue;
            const stType = stInfo & 0x0f;
            // STT_OBJECT = 1, STT_FUNC = 2, STT_NOTYPE = 0
            if (stType !== 1 && stType !== 2 && stType !== 0)
                continue;
            const name = readNullTermString(bytes, strOffset, strSize, stName);
            // Skip compiler mapping symbols ($t, $d, $a) and internal leading-dot labels
            if (!name || name.startsWith("$") || name.startsWith(".L"))
                continue;
            const kind = stType === 2 ? "func" : stType === 1 ? "object" : "other";
            const address = (kind === "func" ? stValue & ~1 : stValue) >>> 0;
            const dedupKey = `${name}@${address}`;
            if (seen.has(dedupKey))
                continue;
            seen.add(dedupKey);
            results.push({ name, address, size: stSize >>> 0, kind });
            if (results.length >= maxSymbols)
                break;
        }
    }
    // Sort: `main` first, then functions before objects, then alphabetical
    results.sort((a, b) => {
        if (a.name === "main" && b.name !== "main")
            return -1;
        if (b.name === "main" && a.name !== "main")
            return 1;
        if (a.kind !== b.kind) {
            if (a.kind === "func")
                return -1;
            if (b.kind === "func")
                return 1;
        }
        return a.name.localeCompare(b.name);
    });
    return results;
}
//# sourceMappingURL=elf.js.map