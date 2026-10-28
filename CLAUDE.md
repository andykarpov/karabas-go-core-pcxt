# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

An IBM PC/XT core for Spartan-6 boards: the PCXT_Xilinx_Spartan_6 port by spark2k06, built on the MCL86 core (8088), KFPC-XT (the chipset), Graphics Gremlin (CGA), JTOPL (Adlib) and an SN76489 (Tandy sound). GPL v3 (LICENSE.txt). The upstream tree builds many boards (ZXUno, ZXDos, NGo, UnoXT, ZXDos+). This repo adds the Karabas Go, Mini and Mini G targets in `ise/XC6SLX25/karabas-go` (Spartan-6 XC6SLX25, ISE 14.7). The core is not converted to `karabas-go-modules`. It has its own MCU link and board modules in `ise/XC6SLX25/karabas-go/rtl`.

## Layout

- `HW/`: the shared RTL of all boards. `system.v` is the PC (it includes `config.vh` from the project dir), plus `8088` (MCL86), `KFPC-XT` (8259, 8253, 8255, 8237, 8288, XT2IDE, keyboard), `video` (CGA, scandoubler, UM6845R), `uart`, `sn76489`, `jtopl` and `common` (`ram.v`, `bram.v`, `dcm.v`, the ROM and splash `.hex` files: `pcxt31.hex`, `xtide.hex`, `splash_karabas_go.hex`).
- `SW/`: `8088_bios`, `ROMs` (the BIOS images and the `make_rom_with_*.py` scripts), `splash`. `hdd/`: DOS tools for the disk image (CTMOUSE, DOSMAX, LTEMM). `doc/`, `releases/`: upstream docs and the upstream board binaries.
- `ise/XC<part>/<board>/`: one ISE project per board. The Karabas dir has `karabas_go_top.v`, `karabas_mini_top.v`, `karabas_minig_top.v`, their `.ucf` and `.xise`, `config.vh`, `ipcore_dir`, and in `rtl/` the MCU link (`mcu/mcu.vhd`, `soft_switches.vhd`, `hid_parser.vhd`, `serial_mouse_convertor.vhd`, ...), `hdmi/`, `dac/`, `adc/`, `spi/`.

## Build

- Karabas boards: open `karabas_go.xise`, `karabas_mini.xise` or `karabas_minig.xise` in `ise/XC6SLX25/karabas-go` in ISE and generate the bitstream. The result is `karabas_<board>_top.bin` in that dir. There is no `build.bat` or script for these targets.
- The upstream boards have `build.bat` / `clean.bat` per dir, and `ise/build_all.py` / `ise/XC6SLX25/build_sc6slx25.py` run them. These are Windows scripts (`start /wait cmd`, `Bit2Bin.exe`, `XILINX_BIN_PATH`).
- `config.vh` picks the board and the features at synthesis time. The Karabas one sets `KARABASGO`, `MEM_4MB`, `SOUND_ADLIB`, `SOUND_TANDY`, `MOUSE_COM1`, `EMULATE_PS2`, `AUDIO_DAC`, `PHYSICAL_IDE`, the BIOS `pcxt31.hex`, the XTIDE BIOS and the splash. All three Karabas tops share it.
- Packing: `make_core.py` in the Karabas dir is a symlink to `../../../../karabas-go-tools/make_core/make_core.py`, so the tools repo must sit next to this one. It packs `core.json` (Go), `core_mini.json`, `core_minig.json` into `pcxt.kg1` / `kg2` / `kg3`. The `.bin` and `.kg*` files are committed.

## MCU link

- `type: "none"`: make_core writes 0xFF, which the firmware calls `CORE_TYPE_HIDDEN`. No `spi_freq` (the default link clock), `eeprom_bank: 255`, `roms: []`.
- The BIOS and the XTIDE BIOS are in block RAM from the `.hex` files, not loaded by the MCU. The top leaves the `ROMLOADER_*` ports of `mcu` open.
- `mcu.vhd` has no `CMD_CAPS` and no burst receiver, so the firmware stays on classic frames.
- `OSD_COMMAND` of `mcu` is not used in the tops (there is no overlay). The soft switches are Video mode (RGB / VGA, Menu+F11), Turbo (Menu+F12) and Reset (Ctrl+Alt+Del). `soft_switches` drives the green / yellow button inputs of `system`.
- Keyboard: the MCU sends XT scancodes with `CMD_PS2_SCANCODE` (0x0B, address 0x01). `mcu.vhd` puts them on `KB_SCANCODE` into `system` (`kb_scancode`). Address 0x00 (the PS/2 sequence) is ignored.
- Mouse: `hid_parser` turns the USB mouse moves of `mcu` into a serial mouse on COM1 (`serial_mouse_convertor`, `MOUSE_TX` / `MOUSE_RTS`).
- Disk: with `PHYSICAL_IDE` the XTIDE talks to the CF card on the `W*` pins, and the SD pins are tied off. Without it `system` uses the FPGA SD card.
- Memory: the 8-bit SRAM (`MA`, `MD[7:0]`). The SDRAM pins are tied off.
- Mini and Mini G: HDMI through `rtl/hdmi` (`hdmi_frame` fits the sync into 720x480, then `hdmi_top`). The Go top has no HDMI files in its project.

## Release

- The Go file is in the release repo `karabas-go` as `cores/pcxt.kg1`; the copy there is the same file as `ise/XC6SLX25/karabas-go/pcxt.kg1`.
- The working branch is `main`. A local branch `mister-update` exists, which is behind `main`.

## Memory

The Claude Code memory of this repo is shared with all karabas-go repos: `~/.claude/projects/<this project>/memory` is a symlink to `../karabas-go-notes` (private repo `andykarpov/karabas-go-notes`, `link.sh` there makes the links). Its `MEMORY.md` is split by repo; commit and push it after every memory change.
