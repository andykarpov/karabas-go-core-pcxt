# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

An IBM PC/XT core for Spartan-6 boards: the PCXT_Xilinx_Spartan_6 port by spark2k06, built on the MCL86 core (8088), KFPC-XT (the chipset), Graphics Gremlin (CGA), JTOPL (Adlib) and an SN76489 (Tandy sound). GPL v3 (LICENSE.txt). The upstream tree builds many boards (ZXUno, ZXDos, NGo, UnoXT, ZXDos+). This repo adds the Karabas Go, Mini and Mini G targets in `ise/XC6SLX25/karabas-go` (Spartan-6 XC6SLX25-2 FTG256, ISE 14.7). On branch `kg-modules` the Karabas targets use `karabas-go-modules` (submodule `modules/`, its `master`): `kg_mcu`, `kg_soft_switches`, `kg_osd_overlay`, `kg_sync`, zhdmi, `kg_pcm5102` / `kg_sigma_delta_dac`; `main` still has the old own MCU link (`mcu.vhd`). The plan of the work on this core (modules, bugs, upstream MiSTer fixes and features, HDD and floppy images) is `docs/PLAN.md` of this repo; work goes on branch `kg-modules`, merged into `main` at the end of the plan.

## Layout

- `modules/`: the submodule `karabas-go-modules` (relative URL `../karabas-go-modules.git`), listed in the `.prj` files as `../../../modules/rtl/...`. Clone with `--recursive` or run `git submodule update --init`.
- `HW/`: the shared RTL of all boards. `system.v` is the PC (it includes `config.vh` from the project dir), plus `8088` (MCL86), `KFPC-XT` (8259, 8253, 8255, 8237, 8288, XT2IDE, keyboard; `Peripherals.v`, `Chipset.v`), `video` (CGA, scandoubler, UM6845R), `uart`, `sn76489`, `jtopl` and `common` (`ram.v`, `bram.v`, `dcm.v`, `clk_div3.v`, the ROM and splash `.hex` files: `pcxt31.hex`, `xtide.hex`, `splash_karabas_go.hex`). A change in `HW/` reaches every board of the upstream tree.
- `SW/`: `8088_bios`, `ROMs` (the BIOS images and the `make_rom_with_*.py` scripts), `splash`. `hdd/`: DOS tools for the disk image (CTMOUSE, DOSMAX, LTEMM). `doc/`, `releases/`: upstream docs and the upstream board binaries.
- `ise/XC<part>/<board>/`: one ISE project per board. The Karabas dir has `karabas_go_top.v`, `karabas_mini_top.v`, `karabas_minig_top.v`, their `.ucf`, the build inputs `.prj` / `.xst` / `.ut`, the `Makefile`, `config.vh` and `rtl/`.
- `rtl/` of the Karabas dir: `karabas_pcxt.v` (the machine all three tops share: `system`, `kg_mcu`, the soft switches, the serial mouse, the OSD overlay; the audio registered in clk_50, `osd_command` taken into clk_vga by a toggle handshake), `mcu/hid_parser.vhd` + `mcu/serial_mouse_convertor.vhd` (the USB mouse as a serial mouse), `hdmi/hdmi_frame.v` (fits the sync into 720x480), `hdmi/zhdmi_top.v` + `hdmi/hdmi_pll.v` (copies of next186's, which fixed the audio sample strobe of the modules version; set to 28.571 MHz). The tops keep the pins, the clocks (`HW/common/dcm.v`), VGA / HDMI and the DAC. Check the `.prj` file list before assuming a file is built.

## Build

- Karabas boards: `Makefile` in `ise/XC6SLX25/karabas-go` (ISE 14.7 command line, sources `/opt/Xilinx/14.7/ISE_DS/settings64.sh`): `make go|mini|minig`, steps `<board>-xst`, `-impl`, `-core`, `make <board>-report`. Inputs per board: `karabas_<board>_top.prj` (the source list, paths relative to the Karabas dir; add new files here), `.xst`, `.ut`, `karabas_<board>.ucf`; the local `.gitignore` un-hides them. Map cost table `MAP_T_<board>` = 2. The results are `karabas_<board>_top.bin` and `pcxt.kg1` / `kg2` / `kg3`; ISE writes its other outputs into the same dir (ignored). There are no `.xise` projects. A Mini G build takes about 4 min (XST 2, map 1, PAR 1).
- The upstream boards have `build.bat` / `clean.bat` per dir, and `ise/build_all.py` / `ise/XC6SLX25/build_sc6slx25.py` run them. These are Windows scripts (`start /wait cmd`, `Bit2Bin.exe`, `XILINX_BIN_PATH`).
- `config.vh` picks the board and the features at synthesis time. The Karabas one sets `KARABASGO`, `MEM_4MB`, `VIRTUAL_BUTTONS`, `SOUND_ADLIB`, `SOUND_TANDY`, `MOUSE_COM1`, `EMULATE_PS2`, `AUDIO_DAC`, `PHYSICAL_IDE`, the BIOS `pcxt31.hex`, the XTIDE BIOS `xtide.hex` and the splash. All three Karabas tops share it. The `HW_ID2` / `HW_ID3` comments in the Mini tops are stale: the projects define no Verilog macros.
- Clocks: `HW/common/dcm.v` makes 100, 50 (`clk_chipset`, the MCU link) and 28.571 MHz (`clk_vga`) from `CLK_50MHZ`. `system.v` divides `clk_vga` to the CPU clock (14.29 MHz, the comments say 14.318) and 4.77 MHz for the peripherals.
- Timing (build 26103022, all three boards): all constraints met. Mini / Mini G 44 % LUTs, 68 % slices; Go 33 %, 54 %; 27 RAMB16. The ucf derives the clocks from `CLK_50MHZ` (`dcm_system` 100 / 50 / 28.571 MHz of one PLL); TIG between 28.571 and 100 / 50 MHz (the upstream design crosses them freely); `TS_AUDIO_PIX` TIG from clk_50 into the HDMI pixel clock (zhdmi_top filters the samples); `TS_CPU_ADDR` 20 ns from `cpu_address` (latched at ALE, held for the bus cycle) to clk_50. `HW/8088/mcl86_eu_core.v` has local `// karabas:` changes (adder on the carry chain, case muxes) that made the 100 MHz EU path meet timing.
- Packing: `make_core.py` in the Karabas dir is a symlink to `../../../../karabas-go-tools/make_core/make_core.py`, so the tools repo must sit next to this one. `make <board>-core` runs it (`core.json` -> `pcxt.kg1`, `core_mini.json` -> `pcxt.kg2`, `core_minig.json` -> `pcxt.kg3`). Set `"build"` (YYMMDDHH) in the json first. The `.bin` and `.kg*` files are committed.

## MCU link

- `type: "osd"` (Menu+Esc opens the OSD; `main` had `none`, which the firmware calls `CORE_TYPE_HIDDEN`: listed in the browser but no OSD). No `spi_freq` (the default 16 MHz link clock), `eeprom_bank: 255`, `roms: []`.
- The BIOS and the XTIDE BIOS are in block RAM from the `.hex` files, not loaded by the MCU. `kg_mcu` has `ENABLE_FILE` 0.
- `kg_mcu` answers `CMD_CAPS` with `BURST_MAX_MHZ`: 32 on Mini G (MCU_SCK on a global clock pin), 0 on Go / Mini (bursts at the link clock). Burst lines: Mini / Mini G `MCU_IO[0]` cs_n (PULLUP) / `MCU_IO[1]` ready; Go `MCU_SPI_IO[1]` cs_n (M11, PULLUP) / `MCU_SPI_IO[0]` ready (N9). No file mounter yet (`ENABLE_IMG` 0, plan Ф4).
- OSD: `kg_osd_overlay` in clk_vga over the 18-bit RGB of `system`, H_OFFSET 120 / V_OFFSET 72 (not tuned on hardware yet).
- Soft switches (`kg_soft_switches` N=3, register n = item n of `core*.json`): 0 Video mode (RGB / VGA, Menu+F11) and 1 Turbo (Menu+F12) drive `btn_green_n_i` / `btn_yellow_n_i` of `system` as levels (`VIRTUAL_BUTTONS` in `Peripherals.v`: scandoubler and turbo follow the switch). 2 Reset (hotkey Ctrl+Alt+Del, a trigger: the firmware sends a pulse) resets the whole PC through `reset_in` of `system` (`kb_reset | areset`; the input exists only with `KARABASGO`, so the other boards keep their ports), as at the end of the splash screen. Ctrl+Alt+Del also reaches the BIOS as keys.
- Keyboard: the MCU sends XT scancodes with `CMD_PS2_SCANCODE` (0x0B, address 0x01). `kg_mcu` puts them on `XT_SCANCODE` (toggle `XT_SCANCODE_UPD`) into `system` (`kb_scancode`). Address 0x00 (the PS/2 sequence) is ignored.
- Mouse: `hid_parser` turns the USB mouse moves of `mcu` into a serial mouse on COM1 (`serial_mouse_convertor`, `MOUSE_TX` / `MOUSE_RTS`).
- Disk: with `PHYSICAL_IDE` the XTIDE talks to the CF card on the `W*` pins (all three boards have them), and the FPGA SD card pins are tied off. Without it `system` uses the FPGA SD card.
- Memory: the 8-bit SRAM (`MA`, `MD[7:0]`, `MWR_N[0]`). The SDRAM, flash, FT812 SPI pins are tied off.
- Video: Go has VGA (6 bits per color padded to 8, `V_CLK`). Mini and Mini G: HDMI (`hdmi_frame`, then `zhdmi_top`, audio on unless `DVI_ONLY`, which crosses into clk_vga through `kg_sync`).
- Audio: `AUD_L` / `AUD_R` of `system` (16 bit, two's complement) to `kg_pcm5102` (Go, Mini G; `DIV_BITS` 2 as before) or `kg_sigma_delta_dac` (Mini, `AUDIO_L` / `AUDIO_R`, a quarter of full scale as before) and HDMI. The ADC pins are tied to 0.
- `FT_CLK_OUT` = clk_50 / 6 = 8.33 MHz on Mini and Mini G (an unclocked FT812 hums into the audio; the rule for all cores).

## Related repositories (siblings in `..`)

- `karabas-go-firmware`: the MCU side of the link (`src/config.h` command codes, `docs/protocol.md`, `docs/burst_protocol.md`).
- `karabas-go-modules`: the shared `kg_*` modules (`kg_mcu` with bursts, `img_sdc`, `hdf_ata`, `kg_soft_switches`, `kg_osd_overlay`, `zhdmi`). `karabas-go-core-next186` is the converted PC core to copy from (Makefile build, OSD, HDD images through `img_sdc` + `hdf_ata`, `FT_CLK_OUT`).
- `karabas-go-tools`: `make_core.py`.
- Release repos: `../karabas-go` (`cores/pcxt.kg1`) and `~/Documents/Projects/Retrocomp/ZX-Spectrum/karabas-mini/karabas-mini` (`cores/pcxt.kg2`, `cores/pcxt.kg3`). Their copies are the same files as `ise/XC6SLX25/karabas-go/pcxt.kg*`.

## Git

- The default branch is `main` (remote `andykarpov/karabas-go-core-pcxt`); the plan work is on `kg-modules`: commits there, no PR per phase, one PR at the end of the plan. The local branch `mister-update` (March 2024) is an ancestor of `main`: fully merged, nothing on it.
- Commits and PRs in English. Commit or push only when the user asks.

## Memory

The Claude Code memory of this repo is shared with all karabas-go repos: `~/.claude/projects/<this project>/memory` is a symlink to `../karabas-go-notes` (private repo `andykarpov/karabas-go-notes`, `link.sh` there makes the links). Its `MEMORY.md` is split by repo; commit and push it after every memory change. The pcxt notes are in `pcxt-backlog.md` and `pcxt-workflow.md`.
