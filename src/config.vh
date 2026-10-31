// The configuration of the PC/XT core of Karabas Go / Mini / Mini G (all three tops include it).

// ROMs: Sergey Kiselev's XT BIOS 1.0.0a of MiSTer PCXT (SW/ROMs/pcxt_xtsergey.rom, 16 KB at
// FC000-FFFFF: 720K / 1.44M floppies, two 1.44M drives, no CMOS) and the XTIDE BIOS (EC000-EFFFF).
// Both start with these files and are written again by the rom loader of kg_mcu from the roms of
// core*.json (0000-3FFF the 16 KB BIOS, an 8 KB one at 2000; 4000-7FFF the XTIDE BIOS). Read only
// for the CPU, as the default of MiSTer 5ab34b8.
`define ROM_BIOS "xtsergey.hex"
`define XTIDE_BIOS "xtide.hex"

// The splash screen at power on
`define SPLASH_ENABLE
`define SPLASH_SCR "splash_karabas_go.hex"

// Sound: Adlib (JTOPL2) and the Tandy sound chip (SN76489) besides the PC speaker
`define SOUND_ADLIB
`define SOUND_TANDY

// The USB mouse of the mcu as a serial mouse on COM1
`define MOUSE_COM1

// The floppy controller of MiSTer PCXT (rtl/common/floppy.v), its disks from the file mounter
`define FLOPPY
`define FDD_CLOCK_RATE 28'd50000000 // the clock of the chipset

// The clock of the mcu at ports 2C0h / 2C1h (MC146818 registers; GET_RTC.EXE in hdd/)
`define RTC_MCU

// MIDI OUT of an MPU-401 in UART mode at 330h / 331h (the synthesizer of the board)
`define MIDI_MPU401

// The game port (201h): two joysticks from the USB pads of the mcu
`define GAME_PORT
