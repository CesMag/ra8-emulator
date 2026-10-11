This PT_LOAD image is the FPU corpus fixture (RA8EMU-143). It is a
Cortex-M85 RA8 image linked at MRAM `0x02000000`. The reset handler turns on
CP10 and CP11 in CPACR, then calls `main`.

`fp_basic.zig` runs VADD, VSUB, VMUL, VDIV, VSQRT and VFMA in single and double
precision over five operand pairs each. The pairs cover exact results,
rounded results, divide by zero and the square root of a negative number.
Before every operation it clears FPSCR, and afterwards it stores the result
and FPSCR at SRAM `0x22000100`. The run ends with the marker `0x0F9C0DE5`.
The source is Zig, so the repository carries no C.

The build names the FP features in `-mcpu` itself rather than relying on
what `cortex_m85` turns on. Rebuild with Zig 0.17.0:

```sh
M=cortex_m85+fp_armv8d16+fullfp16
zig cc -target thumb-freestanding-eabihf -mcpu=$M -c startup.S -o startup.o
zig build-obj -target thumb-freestanding-eabihf -mcpu=$M -O ReleaseSmall -fno-stack-check -fstrip -fno-compiler-rt -ffunction-sections fp_basic.zig -femit-bin=fp_basic.o
zig cc -target thumb-freestanding-eabihf -mcpu=$M -nostdlib -Wl,--build-id=none -Wl,--gc-sections -Wl,-s -Wl,-e,Reset_Handler -Wl,-z,max-page-size=4 -Wl,-T,fpu.ld startup.o fp_basic.o -o fp_basic.elf
```

`tests/chip/core/cpu/fp_corpus_test.zig` embeds this exact ELF and boots it
through the Zig core. Its expected words come from the Arm ARM (DDI0553)
FPAdd, FPSub, FPMul, FPDiv, FPSqrt and FPMulAdd pseudocode, rounding to
nearest even. FPSCR is compared on its cumulative flag bits.

`fp_cvt.zig` covers the scalar conversions and round-to-integral ops:
VCVT/VCVTR/VCVTA/VCVTN/VCVTP/VCVTM to S32 and U32, VCVT between F32, F64 and
S32/U32, VCVTB between F16 and F32, and VRINTA/N/P/M/Z/X/R. Inputs include
ties, negatives, values out of integer range, NaNs (quiet and signalling),
half-precision overflow and subnormals. It stores each result with
`FPSCR & 0x9F`. Build it with the same three commands, swapping `fp_basic`
for `fp_cvt`. `tests/chip/core/cpu/fp_cvt_corpus_test.zig` boots it; the expected
words in `fp_cvt_vectors.zig` come from the DDI0553 FPToFixed, FixedToFP,
FPRoundInt and FPConvert pseudocode.

`fp_cmp.zig` runs VCMP, VCMPE (register and `#0`), VMAXNM and VMINNM in single
and double precision over ordered pairs, equal values, signed zeros,
infinities, subnormals and quiet and signalling NaNs in both operand
positions. Compares store `FPSCR & 0xF000009F` (NZCV and flags); min and max
store the result too. Build it the same way, swapping in `fp_cmp`.
`tests/chip/core/cpu/fp_cmp_corpus_test.zig` boots it; `fp_cmp_vectors.zig` holds
the DDI0553 FPCompare, FPMaxNum and FPMinNum words.

`fp_modes.zig` checks the remaining architectural modes. It runs RNE, RP,
RM and RZ over half-ULP addition, division and VCVTR; fixed-point VCVT;
FZ on an F32 subnormal; DN on quiet and signalling NaNs; and F16 VADD,
VMUL, VDIV, VSQRT and VFMA plus FZ16. Each operation stores its result and
`FPSCR & 0x03C0009F`, including the control mode. Build it the same way,
swapping in `fp_modes`. `fp_modes_corpus_test.zig` boots it and compares
against the DDI0553 words in `fp_modes_vectors.zig`.

`lob.zig` is the low-overhead-loop corpus (RA8EMU-232). For trip counts 0,
1, 3, 4, 5, 16, 17, 37 and 64 (read back from SRAM so nothing folds) it runs
word and byte sums, a word add, a halfword scale, a halfword dot product and
a word hash. LLVM only turns these into DLSTP.8/.16/.32 with LETP, plain LE
loops and Helium bodies at `-O ReleaseFast` with MVE on, so build it with
`M=cortex_m85+mve_fp+fp_armv8d16+fullfp16` and `-O ReleaseFast` in the
second command, swapping in `lob`. `lob_corpus_test.zig` boots it on the
Zig core and compares against the host-worked words in `lob_vectors.zig`.

`dsp.zig` is the Helium DSP corpus (RA8EMU-116). For trip counts 0, 1, 7,
8, 9, 31 and 64 (read back from SRAM) it runs CMSIS-DSP shaped kernels: q15
and q31 dot products, q15 and q7 saturating adds, a q31 scale, a q15 max,
an 8-tap q15 FIR and a fused f32 dot product, storing eight words per count.
Build it like `lob` (`M=cortex_m85+mve_fp+fp_armv8d16+fullfp16`,
`-O ReleaseFast`), swapping in `dsp`. `dsp_corpus_test.zig` boots it on the
Zig core and compares against the host-worked words in `dsp_vectors.zig`.

`nnf.zig` is the TFLM / CMSIS-NN float corpus (RA8EMU-321). For trip counts
0, 1, 5, 8, 13 and 32 (read back from SRAM) it runs float kernel shapes: a
fused fully-connected layer, element-wise add and mul with ReLU, a max, int8
dequantize, round-to-nearest requantize, F16 fused dot products (one after
narrowing F32 into an operand) and an abs-and-scale pass, storing eight words
per count. Build it like `lob`, swapping in `nnf`. `nnf_corpus_test.zig`
boots it on the Zig core and compares against the host-worked words in
`nnf_vectors.zig`. The dequantize scale is 9/128 on purpose: with a power of
two, LLVM folds the multiply into a fixed-point VCVT whose
fraction-bit count does not match the source (see RA8EMU-321).
