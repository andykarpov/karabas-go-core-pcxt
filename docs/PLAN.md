# План развития PCXT-ядра Karabas Go

Цели (список пользователя, 2026-10-30):

1. Подключить `karabas-go-modules`.
2. Исправить баги.
3. Перенести исправления из upstream (MiSTer `PCXT_MiSTer`).
4. Монтирование образов HDD и дискет через file mounter прошивки, по аналогии с nanomig.

Затрагиваемые репозитории:

| Репозиторий | Что меняется |
|---|---|
| `karabas-go-core-pcxt` | топы, `HW/` (общий RTL всех плат upstream), сборка, `core*.json` |
| `karabas-go-modules` | по необходимости: `hdf_ata` (8-битный доступ / XT-IDE), адаптер дисковода, тесты |
| `karabas-go-firmware` | скорее всего ничего: file mounter (`F`-слоты, `CMD_IMG_*`) уже есть |
| `karabas-go-tools` | ничего |

## 0. Исходное состояние

- Upstream: `spark2k06/PCXT_Xilinx_Spartan_6` (последний коммит d3ed716, 2023-05-21) плюс правки под Karabas: `config.vh` (`KARABASGO`), топы и `rtl/` в `ise/XC6SLX25/karabas-go`, а также локальные изменения общих файлов `HW/` (`common/dcm.v`, `KFPC-XT/HDL/Chipset.v`, `Peripherals.v`, `KFPS2KB*.v`, `system.v`, `video/cga_scandoubler.v`).
- Сборка только из ISE GUI (`.xise`, `map -t 1`). Makefile нет.
- MCU-линк — старая копия `mcu.vhd`: нет `CMD_CAPS`, burst и file mounter. Тип ядра `none`: OSD нет, работают только горячие клавиши пунктов.
- Диск: XTIDE на CF-карте (пины `W*`, есть на всех трёх платах). Дисковода нет.
- Ресурсы (Go / Mini / Mini G): слайсы 53 / 61 / 61 %, RAMB16 25 из 52, DSP 1–2 из 38. Места достаточно.
- Тайминг закоммиченных сборок не сходится: Go `clk_100` / `clk_50` до −1.05 нс; Mini / Mini G клоки HDMI PLL около −5 нс.
- Найденные баги (по коду):
  - пункт OSD Reset ничего не сбрасывает: `kb_reset` уходит в неподключённый `btn_reset_n`. Ctrl+Alt+Del работает только через BIOS;
  - `FT_CLK_OUT` = 0 на Mini / Mini G (FT812 без клока даёт гул);
  - `MS_Z` подключён к необъявленному `ms_z`;
  - клок `clk_vga` 28.571 МГц вместо 28.636: CPU и PIT медленнее на 0.2 %.

Upstream MiSTer (`MiSTer-devel/PCXT_MiSTer`, efce777, 2026-10-12): после нашей точки ответвления 104 коммита. Он **на SystemVerilog** (`*.sv`: CPU `mcl86_*.sv`, `Peripherals.sv`, `Chipset.sv`, ...), а XST SV не понимает. Поэтому исправления переносятся вручную, по одному, на Verilog-2001, а не копированием файлов.

## Ф0. Сборка из командной строки и baseline

- Makefile в `ise/XC6SLX25/karabas-go` (там же, где топы: пути к `../../../HW` не меняются). Цели `go|mini|minig`, шаги `-xst`, `-impl`, `-core`, `-report`; tracked `.prj` / `.xst` / `.ut` на плату; `MAP_T_<board>` = 2. `.xise` удаляются.
- `.gitignore` для выходных файлов ISE.
- Baseline: сборка текущего кода (сначала Mini G), таблица LUT / слайсов / тайминга для сравнения на следующих фазах.

Baseline Mini G (2026-10-30, Makefile, `map -t 2`, код `main`, ~4 мин): LUT 5715 (38 %), слайсы 2260 (60 %), RAMB16 25, RAMB8 4, DSP 2; 3 constraints не выполнены, Timing Score 117909: `hdmi_pll_clk0` −5.205 нс, `hdmi_pll_clkfx` −1.869 нс, `clk_100` (`dcm_system_clkout0`) −0.759 нс (107 путей). Go и Mini: данные коммитнутых сборок (см. раздел 0), пересобираются в Ф1.

## Ф1. Подключение karabas-go-modules

- Сабмодуль `modules/` в корне репо (URL `../karabas-go-modules.git`); в `.prj` пути `../../../modules/rtl/...`.
- `mcu.vhd` → `kg_mcu` (`CMD_CAPS`; burst на Mini G с `BURST_MAX_MHZ` 32, как в next186), `soft_switches.vhd` → `kg_soft_switches`, `spi_slave` из modules.
- OSD: `kg_osd_overlay` на выходе видео, тип ядра `osd` (Menu+Esc), пункты Video mode, Turbo, Reset и далее пункты Ф4/Ф5.
- HDMI: `rtl/hdmi` → `zhdmi` из modules (с исправлениями sync / звука из next186), `hdmi_frame` остаётся, если `zhdmi` его не заменяет.
- Звук: `pcm5102.v` → `kg_pcm5102`, `dac.vhd` → `kg_sigma_delta_dac`.
- `FT_CLK_OUT` ≈ 8 МГц на Mini / Mini G.
- Constraints: PERIOD на `CLK_50MHZ`, производные на выходы DCM / PLL, переходы между клоками через `kg_sync` / FIFO, а не TIG. Цель — все constraints выполнены на трёх платах.
- Удалить неиспользуемые файлы `rtl/` (список в CLAUDE.md).

## Ф2. Баги

Сделано 2026-10-30 (сборка 26103022): OSD Reset сбрасывает весь PC (вход `reset_in` в `system` под `KARABASGO`). Неявных проводов в коде Karabas больше нет (`ms_z` ушёл с `kg_mcu`). Предупреждения XST в общем коде проверены: ширина `tandy_snd_e` (sn76489 без знака, 0..124, дополнение нулями верно), `hdmi_frame` — не баги. Частота 28.636 МГц перенесена в Ф3: нужен отдельный PLL для `clk_vga`, тогда клоки CPU и чипсета станут асинхронными, а MiSTer решал это вместе с переходом на clock enable («XT timing: drive the chipset with exact clock enables»).

- OSD Reset: вход сброса в `system` (холодный сброс без splash screen), от `kb_reset` и от `mcu_busy` / загрузки.
- `ms_z`, прочие неявные провода (проверить предупреждения XST).
- Клок 28.636 МГц (или clock enable с точной частотой, как в MiSTer «exact clock enables»), если это влезает в DCM / PLL.
- Других известных пользователю багов нет (2026-10-30).

## Ф3. Исправления из upstream

1. Инвентаризация: 104 коммита MiSTer после 2023-05 плюс отличия до этой даты, разложенные по категориям, с оценкой «нужно / не нужно / дорого». Обсудить с пользователем.
2. Кандидаты (по заголовкам коммитов):
   - чипсет (kitune-san, 2023-08): ошибки POST 101 / 601 после горячего сброса и в турбо, задержка INT 8259A, тайминг INTR, клавиатура после warm boot;
   - CPU: INTR между итерациями REP, тайминг LODS / STOSB / IN, укороченный критический путь EU;
   - PIT: старое значение счётчика до записи обоих байтов;
   - RAM: удержание байта записи после MEMW;
   - CRTC / CGA: адрес начала кадра, HSYNC / VSYNC, бордюр;
   - RTC: alarm second;
   - сброс OPL по Ctrl+Alt+Del;
   - BIOS: новая версия XT BIOS Сергея Кисилёва.
3. Новые функции upstream (HGC, композит, SAA1099 / CMS, MIDI, режим 8086, EMS-варианты): тоже переносятся (решение пользователя 2026-10-30), после исправлений, по одной, с проверкой ресурсов и тайминга на каждой; что не влезает в XC6SLX25 или не имеет смысла на плате (композит без композитного выхода и т.п.) — отмечается в инвентаризации и обсуждается.

Каждое исправление — отдельный коммит с ссылкой на коммит upstream; общие файлы `HW/` меняются так, чтобы сборки других плат upstream не ломались (или они явно не поддерживаются).

## Ф4. Образы HDD

- `img_sdc` + `hdf_ata` из modules, по образцу nanomig / next186. Слоты `HDD0` / `HDD1` (`.img .vhd .bin .raw`).
- Подключение: XT-IDE BIOS работает через `XT2IDE.v` (8-битная шина XT → 16-битный IDE). `hdf_ata` встаёт на место CF-карты за `XT2IDE` (16-битная сторона), как CF / HDF в nanomig: устройство 0 — CF или образ, устройство 1 — образ. Пункт OSD «HDD0: CF card / Image».
- Сброс `hdf_ata` от сброса CPU (урок next186).
- Тест в симуляции: `tb_ata` (XT2IDE + `hdf_ata` + `img_sdc` + модель MCU), чтение и запись, до и после сброса.
- Известная проблема `hdf_ata` из modules: гонка при монтировании (нет BSY во время чтения геометрии) — исправлять в modules вместе с nanomig / next186, по согласованию.

## Ф5. Образы дискет

- FDC: `floppy.v` из MiSTer (ao486, Aleksander Osman / Alexey Melnikov, BSD-лицензия; немного SV — перевести на Verilog-2001). Порты 0x3F0–0x3F7, DMA канал 2 (`dma_request[2]` уже выведен из `Chipset`), IRQ 6.
- Его интерфейс `mgmt` (сектора от HPS MiSTer) заменить на запросы к `img_sdc`: слоты `FDD A` / `FDD B` (`.img .ima`, 360K / 720K / 1.2M / 1.44M по размеру файла), write protect.
- DIP-переключатели числа дисководов — по наличию образов (как «floppy presence» в MiSTer).
- Тест в симуляции: чтение сектора через DMA, смена дискеты.
- Позже, по желанию: физический дисковод на Go (как в nanomig).

## Порядок работы

- Сначала Mini G (основная плата для тестов), Go и Mini — к релизу.
- Коммиты в рабочие ветки без PR; PR и merge в `main` только в конце всего плана (решение пользователя 2026-10-30, как в nes). Ветка ядра `kg-modules`; в modules, если понадобится, ветка `pcxt-core`.
- Проверка на железе в конце каждой фазы (пользователь; спрашивать перед прошивкой).
