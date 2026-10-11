ENTRY(Reset_Handler)
MEMORY
{
  FLASH (rx) : ORIGIN = 0x02000000, LENGTH = 512K
  SRAM (rwx) : ORIGIN = 0x22000000, LENGTH = 512K
}
SECTIONS
{
  .text ORIGIN(FLASH) : { KEEP(*(.isr_vector)) *(.text*) *(.rodata*) } > FLASH
  .bss (NOLOAD) : { *(.bss*) *(COMMON) } > SRAM
}
