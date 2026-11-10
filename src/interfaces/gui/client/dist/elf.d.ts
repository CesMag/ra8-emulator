/**
 * Lightweight ARM ELF32 Inspector & IEEE CRC32 Calculator
 *
 * Zero-dependency browser/Node helper for validating 32-bit ARM ELF images,
 * computing CRC32 checksums for RA8 chunked RPC uploads (LoadBegin), and
 * extracting .symtab functions/globals + DWARF presence for instant UI search.
 */
import { ElfSymbol } from "./types.js";
/** Standard IEEE 802.3 CRC32 matching Zig `std.hash.Crc32.hash` */
export declare function crc32(bytes: Uint8Array): number;
export interface ElfHeaderInfo {
    valid: boolean;
    entry: number;
    machine: number;
    hasDebugInfo: boolean;
    reason?: string;
}
/** Validate that a buffer is a 32-bit Little-Endian ARM ELF executable */
export declare function inspectElf(bytes: Uint8Array): ElfHeaderInfo;
/** Extract function and global object symbols from an ARM ELF32 binary */
export declare function parseElfSymbols(bytes: Uint8Array, maxSymbols?: number): ElfSymbol[];
//# sourceMappingURL=elf.d.ts.map