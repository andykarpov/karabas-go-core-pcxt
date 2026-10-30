# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

An IBM PC/XT core for Spartan-6 boards: the PCXT_Xilinx_Spartan_6 port by spark2k06, built on the MCL86 core (8088), KFPC-XT (the chipset), Graphics Gremlin (CGA), JTOPL (Adlib) and an SN76489 (Tandy sound). GPL v3 (LICENSE.txt). The upstream tree builds many boards (ZXUno, ZXDos, NGo, UnoXT, ZXDos+). This repo adds the Karabas Go, Mini and Mini G targets in `ise/XC6SLX25/karabas-go` (Spartan-6 XC6SLX25-2 FTG256, ISE 14.7). The core is not converted to `karabas-go-modules` (stage 4 of its `docs/PLAN.md`): it has its own MCU link and board modules in `ise/XC6SLX25/karabas-go/rtl`, and builds from `.xise` projects in the ISE GUI.

## Layout

- `HW/`: the shared RTL of all boards. `system.v` is the PC (it includes `config.vh` from the project dir), plus `8088` (MCL86), `KFPC-XT` (8259, 8253, 8255, 8237, 8288, XT2IDE, keyboard; `Peripherals.v`, `Chipset.v`), `video` (CGA, scandoubler, UM6845R), `uart`, `sn76489`, `jtopl` and `common` (`ram.v`, `bram.v`, `dcm.v`, `clk_div3.v`, the ROM and splash `.hex` files: `pcxt31.hex`, `xtide.hex`, `splash_karabas_go.hex`). A change in `HW/` reaches every board of the upstream tree.
- `SW/`: `8088_bios`, `ROMs` (the BIOS images and the `make_rom_with_*.py` scripts), `splash`. `hdd/`: DOS tools for the disk image (CTMOUSE, DOSMAX, LTEMM). `doc/`, `releases/`: upstream docs and the upstream board binaries.
- `ise/XC<part>/<board>/`: one ISE project per board. The Karabas dir has `karabas_go_top.v`, `karabas_mini_top.v`, `karabas_minig_top.v`, their `.ucf` and `.xise`, `config.vh`, `ipcore_dir` (`rtc`, `queue`: the fifo of `mcu.vhd`), and `rtl/`.
- `rtl/` of the Karabas dir, used by the projects: `mcu/mcu.vhd`, `mcu/soft_switches.vhd`, `mcu/hid_parser.vhd`, `mcu/serial_mouse_convertor.vhd`, `spi/spi_slave.vhd`, `dac/pcm5102.v` (Go, Mini G), `dac/dac.vhd` (Mini), `hdmi/*` (Mini, Mini G). Not in any project (leftovers): `KFPS2KB_emu.v`, `MSMouseWrapper_emu.v`, `adc/`, `fifo/`, `ram/`, `mcu/cursor.vhd`, `debounce.vhd`, `hid_typematic.vhd`, `ps2_transceiver.vhd`, `usb_ps2_*`, `spi/spi_master.vhd`, `hdmi/audio_*`, `hdmi/freq_counter.vhd`. Check the `.xise` file list before assuming a file is built.

## Build

- Karabas boards: open `karabas_go.xise`, `karabas_mini.xise` or `karabas_minig.xise` in `ise/XC6SLX25/karabas-go` in ISE and generate the bitstream. The result is `karabas_<board>_top.bin` in that dir. There is no Makefile or script for these targets yet (a conversion would add `src/Makefile`-style targets like the converted cores, with `map -t 2`). The `.xise` projects map with `-t 1`.
- ISE writes its outputs next to the sources; the `.gitignore` of the repo hides them. Tracked in the Karabas dir: the tops, `.ucf`, `.xise`, `config.vh`, `core*.json`, `karabas_*_top.bin`, `pcxt.kg*`, `ipcore_dir`, `rtl`.
- The upstream boards have `build.bat` / `clean.bat` per dir, and `ise/build_all.py` / `ise/XC6SLX25/build_sc6slx25.py` run them. These are Windows scripts (`start /wait cmd`, `Bit2Bin.exe`, `XILINX_BIN_PATH`).
- `config.vh` picks the board and the features at synthesis time. The Karabas one sets `KARABASGO`, `MEM_4MB`, `VIRTUAL_BUTTONS`, `SOUND_ADLIB`, `SOUND_TANDY`, `MOUSE_COM1`, `EMULATE_PS2`, `AUDIO_DAC`, `PHYSICAL_IDE`, the BIOS `pcxt31.hex`, the XTIDE BIOS `xtide.hex` and the splash. All three Karabas tops share it. The `HW_ID2` / `HW_ID3` comments in the Mini tops are stale: the projects define no Verilog macros.
- Clocks: `HW/common/dcm.v` makes 100, 50 (`clk_chipset`, the MCU link) and 28.571 MHz (`clk_vga`) from `CLK_50MHZ`. `system.v` divides `clk_vga` to the CPU clock (14.29 MHz, the comments say 14.318) and 4.77 MHz for the peripherals.
- Timing: the committed builds do not meet their constraints (from the `.par`, Jan 2026): Go fails `clk_100` / `clk_50` by up to 1.05 ns; Mini and Mini G fail the HDMI PLL clocks by about 5 ns and `clk_100` / `clk_50` slightly. They work on hardware anyway. Slices: Go 53 %, Mini / Mini G 61 %, so there is room for features.
- Packing: `make_core.py` in the Karabas dir is a symlink to `../../../../karabas-go-tools/make_core/make_core.py`, so the tools repo must sit next to this one. Run it from the Karabas dir: `python3 make_core.py core.json pcxt.kg1`, `core_mini.json` -> `pcxt.kg2`, `core_minig.json` -> `pcxt.kg3`. Set `"build"` (YYMMDDHH) in the json first. The `.bin` and `.kg*` files are committed.

## MCU link

- `type: "none"`: make_core writes 0xFF, which the firmware calls `CORE_TYPE_HIDDEN`: the core is still listed in the browser (`visible: true`), but Menu+Esc opens no OSD. The hotkeys of the `osd` items still work (they send `CMD_SWITCHES` with the item index). No `spi_freq` (the default 16 MHz link clock), `eeprom_bank: 255`, `roms: []`.
- The BIOS and the XTIDE BIOS are in block RAM from the `.hex` files, not loaded by the MCU. The tops leave the `ROMLOADER_*` ports of `mcu` open.
- `mcu.vhd` has no `CMD_CAPS` and no burst receiver, so the firmware stays on classic frames. It has no file mounter (`CMD_IMG_*`), so there are no image slots.
- `OSD_COMMAND` of `mcu` is not used in the tops (there is no overlay).
- Soft switches (`soft_switches.vhd`, index = item position in `core*.json`): 0 Video mode (RGB / VGA, Menu+F11) and 1 Turbo (Menu+F12) drive `btn_green_n_i` / `btn_yellow_n_i` of `system` as levels (`VIRTUAL_BUTTONS` in `Peripherals.v`: scandoubler and turbo follow the switch). 2 Reset (hotkey Ctrl+Alt+Del) sets `kb_reset`, which goes only into `btn_reset_n` (an implicit wire, connected to nothing) and the HDMI reset: the OSD reset does not reset the PC. Ctrl+Alt+Del still reboots because the keys also reach the core and the BIOS handles them. `system` resets only after the splash screen.
- Keyboard: the MCU sends XT scancodes with `CMD_PS2_SCANCODE` (0x0B, address 0x01). `mcu.vhd` puts them on `KB_SCANCODE` into `system` (`kb_scancode`). Address 0x00 (the PS/2 sequence) is ignored.
- Mouse: `hid_parser` turns the USB mouse moves of `mcu` into a serial mouse on COM1 (`serial_mouse_convertor`, `MOUSE_TX` / `MOUSE_RTS`). `MS_Z` of `mcu` goes to an undeclared (implicit) `ms_z`.
- Disk: with `PHYSICAL_IDE` the XTIDE talks to the CF card on the `W*` pins (all three boards have them), and the FPGA SD card pins are tied off. Without it `system` uses the FPGA SD card.
- Memory: the 8-bit SRAM (`MA`, `MD[7:0]`, `MWR_N[0]`). The SDRAM, flash, FT812 SPI pins are tied off.
- Video: Go has VGA (6 bits per color padded to 8). Mini and Mini G: HDMI through `rtl/hdmi` (`hdmi_frame` fits the sync into 720x480, then `hdmi_top`, audio on unless `DVI_ONLY`).
- Audio: `AUD_L` / `AUD_R` of `system` (16 bit) to the PCM5102 (Go, Mini G; Mini: `dac.vhd` on `AUDIO_L` / `AUDIO_R`) and HDMI. The ADC pins are tied to 0.
- `FT_CLK_OUT` is tied to 0 on Mini and Mini G (an ODDR2 at 8 MHz is commented out). That breaks the rule for all cores: an unclocked FT812 hums into the audio; drive it with about 8 MHz (ODDR2 or a divider) when the tops are next touched.

## Related repositories (siblings in `..`)

- `karabas-go-firmware`: the MCU side of the link (`src/config.h` command codes, `docs/protocol.md`, `docs/burst_protocol.md`).
- `karabas-go-modules`: the shared `kg_*` modules (`kg_mcu` with bursts, `img_sdc`, `hdf_ata`, `kg_soft_switches`, `kg_osd_overlay`, `zhdmi`). `karabas-go-core-next186` is the converted PC core to copy from (Makefile build, OSD, HDD images through `img_sdc` + `hdf_ata`, `FT_CLK_OUT`).
- `karabas-go-tools`: `make_core.py`.
- Release repos: `../karabas-go` (`cores/pcxt.kg1`) and `~/Documents/Projects/Retrocomp/ZX-Spectrum/karabas-mini/karabas-mini` (`cores/pcxt.kg2`, `cores/pcxt.kg3`). Their copies are the same files as `ise/XC6SLX25/karabas-go/pcxt.kg*`.

## Git

- The working branch is `main` (remote `andykarpov/karabas-go-core-pcxt`). The local branch `mister-update` (March 2024) is an ancestor of `main`: fully merged, nothing on it.
- Commits and PRs in English. Commit or push only when the user asks.

## Memory

The Claude Code memory of this repo is shared with all karabas-go repos: `~/.claude/projects/<this project>/memory` is a symlink to `../karabas-go-notes` (private repo `andykarpov/karabas-go-notes`, `link.sh` there makes the links). Its `MEMORY.md` is split by repo; commit and push it after every memory change. The pcxt notes are in `pcxt-backlog.md`.
