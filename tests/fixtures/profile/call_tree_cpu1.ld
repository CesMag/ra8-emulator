ENTRY(Reset_Handler)
MEMORY
{
  FLASH (rx) : ORIGIN = 0x020C0000, LENGTH = 256K
  SRAM (rwx) : ORIGIN = 0x22190000, LENGTH = 64K
}
SECTIONS
{
  .text ORIGIN(FLASH) : { KEEP(*(.isr_vector)) *(.text*) *(.rodata*) } > FLASH
  .bss (NOLOAD) : { *(.bss*) *(COMMON) } > SRAM
}
