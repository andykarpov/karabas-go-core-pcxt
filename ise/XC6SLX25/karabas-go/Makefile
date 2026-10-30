# Command line build of the PCXT core for the three Karabas boards: the steps and options of the ISE 14.7
# project navigator (the .xise projects of the boards, removed since).
#
#   make                 all three boards (pcxt.kg1, pcxt.kg2, pcxt.kg3)
#   make go|mini|minig   one board: synthesis, implementation, bitstream, .kg file
#   make minig-xst       one step: <board>-xst (.ngc), <board>-impl (.bin), <board>-core (.kg)
#   make minig-report    LUTs, slices, block RAMs and the timing result of the last build
#   make clean           the intermediate files (not the .bin / .kg files, they are in git)
#
# Inputs per board: karabas_<board>_top.prj, .xst, karabas_<board>.ucf, karabas_<board>_top.ut.
# A step runs again when one of its inputs is newer than its output.
# The boards share xst/ and _ngo/, so they are built one after the other.

ISE_SETTINGS ?= /opt/Xilinx/14.7/ISE_DS/settings64.sh
PART = xc6slx25-ftg256-2
BOARDS = go mini minig

SHELL = /bin/bash
.SHELLFLAGS = -e -o pipefail -c
.NOTPARALLEL:
# settings64.sh takes the arguments of the shell that sources it: none here
XIL = source $(ISE_SETTINGS) > /dev/null;

KG_go = pcxt.kg1
KG_mini = pcxt.kg2
KG_minig = pcxt.kg3
JSON_go = core.json
JSON_mini = core_mini.json
JSON_minig = core_minig.json

# map / par options (as the .xise projects had them, but cost table 2)
MAP_T_go = 2
MAP_T_mini = 2
MAP_T_minig = 2
MAP_OPTS = -logic_opt off -ol high -xt 3 -register_duplication off -r 4 -global_opt off -mt off -ir off -pr off -lc off -power off
PAR_OPTS = -ol high -mt off

# included by the sources, not in the prj
INCLUDES = config.vh $(wildcard ../../../HW/common/*.hex ../../../HW/video/*.hex)

.PHONY: all clean $(BOARDS) $(BOARDS:=-xst) $(BOARDS:=-impl) $(BOARDS:=-core) $(BOARDS:=-report)

all: $(BOARDS)

define board
SRC_$(1) := $$(shell sed -n 's/^[a-z]* work "\(.*\)"/\1/p' karabas_$(1)_top.prj)

karabas_$(1)_top.ngc: karabas_$(1)_top.prj karabas_$(1)_top.xst $$(SRC_$(1)) $(INCLUDES)
	mkdir -p xst/projnav.tmp
	$(XIL) xst -intstyle ise -ifn karabas_$(1)_top.xst -ofn karabas_$(1)_top.syr

karabas_$(1)_top.bin: karabas_$(1)_top.ngc karabas_$(1).ucf karabas_$(1)_top.ut
	$(XIL) ngdbuild -intstyle ise -dd _ngo -sd ipcore_dir -nt timestamp -uc karabas_$(1).ucf -p $(PART) karabas_$(1)_top.ngc karabas_$(1)_top.ngd
	$(XIL) map -intstyle ise -p $(PART) -w $(MAP_OPTS) -t $(MAP_T_$(1)) -o karabas_$(1)_top_map.ncd karabas_$(1)_top.ngd karabas_$(1)_top.pcf
	$(XIL) par -w -intstyle ise $(PAR_OPTS) karabas_$(1)_top_map.ncd karabas_$(1)_top.ncd karabas_$(1)_top.pcf
	$(XIL) trce -intstyle ise -v 3 -s 2 -n 3 -fastpaths -xml karabas_$(1)_top.twx karabas_$(1)_top.ncd -o karabas_$(1)_top.twr karabas_$(1)_top.pcf -ucf karabas_$(1).ucf
	$(XIL) bitgen -intstyle ise -f karabas_$(1)_top.ut karabas_$(1)_top.ncd

$(KG_$(1)): karabas_$(1)_top.bin $(JSON_$(1))
	python3 make_core.py $(JSON_$(1)) $$@

$(1): $(KG_$(1))
$(1)-xst: karabas_$(1)_top.ngc
$(1)-impl: karabas_$(1)_top.bin
$(1)-core: $(KG_$(1))
$(1)-report:
	@grep -E "Number of (Slice LUTs|occupied Slices|RAMB16BWERs|RAMB8BWERs|DSP48A1s):" karabas_$(1)_top_map.mrp
	@grep -E "constraints? (was|were) met|constraints? not met|Timing Score" karabas_$(1)_top.par | sort -u
endef

$(foreach b,$(BOARDS),$(eval $(call board,$(b))))

clean:
	rm -rf _ngo _xmsgs xlnx_auto_0_xdb xst iseconfig
	rm -f *.bgn *.bit *.bld *.drc *.ncd *.ngc *.ngd *.ngr *.pad *.par *.pcf *.ptwx *.stx
	rm -f *.unroutes *.xpi *.map *.mrp *.ngm *.xrpt *.twr *.twx *.lso *.syr *.csv *_pad.txt
	rm -f *.cmd_log *.log *.xml *.html *.xwbt *.gise
