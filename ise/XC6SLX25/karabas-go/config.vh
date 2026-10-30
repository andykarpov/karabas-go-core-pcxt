// Model

// XC6SLX9 (ZXUno Family)
// `define ZXUNO_512KB 
// `define ZXUNO_2MB
// `define ZXUNO_2MB_EXT
// `define ZXUNCORE_512KB
// `define ZXUNCORE_2MB
// `define VGAWIFI

// XC6SLX16 (ZXDos Family)
// `define ZXDOS_512KB
// `define ZXDOS_1MB
// `define NGO

// XC6SLX25 (ZXDos+ Family)
// `define ZXDOSPLUS
// `define UNOXT
//`define UNOXT2
`define KARABASGO

// ROMs

`define BIOS_WRITABLE = 1'b1;   // 0=No, 1=Yes

// `define ROM_BIOS "pcxt31.hex" // 8Kb BIOS (Turbo XT BIOS 3.1: 360K floppies only)
// karabas: Sergey Kiselev's XT BIOS 1.0.0a of MiSTer PCXT (SW/ROMs/pcxt_xtsergey.rom, FC000-FFFFF):
// 720K / 1.44M floppies (two 1.44M drives, no CMOS)
`define BIOS_16KB
// karabas: the BIOS and the XTIDE BIOS also from the roms of core*.json (the mcu rom loader:
// 0000-3FFF the 16 KB BIOS, an 8 KB one at 2000; 4000-7FFF the XTIDE BIOS); needs BIOS_16KB
`define ROM_LOADER
`define ROM_BIOS "xtsergey.hex" // 16Kb BIOS
`define XTIDE_BIOS "xtide.hex" // Up to 16Kb

// Splash Screen

`define SPLASH_ENABLE
// `define SPLASH_SCR "splash_zxuno_512kb.hex"
// `define SPLASH_SCR "splash_zxuno_2mb.hex"
// `define SPLASH_SCR "splash_zxuncore_512kb.hex"
// `define SPLASH_SCR "splash_zxuncore_2mb.hex"

// `define SPLASH_SCR "splash_zxdos_512kb.hex"
// `define SPLASH_SCR "splash_zxdos_1mb.hex"
// `define SPLASH_SCR "splash_ngo.hex"

// `define SPLASH_SCR "splash_unoxt.hex"
//`define SPLASH_SCR "splash_unoxt2.hex"
// `define SPLASH_SCR "splash_zxdosplus.hex"
`define SPLASH_SCR "splash_karabas_go.hex"

// Memory
// `define MEM_512KB
// `define MEM_1MB
// `define MEM_2MB
`define MEM_4MB
 
//`define PHISICAL_BUTTONS
`define VIRTUAL_BUTTONS
`define SOUND_ADLIB
`define SOUND_TANDY
`define MOUSE_COM1
`define EMULATE_PS2
`define AUDIO_DAC
`define PHYSICAL_IDE
// the floppy controller of MiSTer PCXT (HW/common/floppy.v), its disks from the file mounter
`define FLOPPY
`define FDD_CLOCK_RATE 28'd50000000 // the clock of the chipset
