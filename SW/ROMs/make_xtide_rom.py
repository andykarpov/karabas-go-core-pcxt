#!/usr/bin/env python3
# karabas: the XTIDE Universal BIOS image of the core (src/rom/xtide.rom, rtl/common/xtide.hex) from
# the XT large build of xtideuniversalbios.org (binaries/r638/ide_xtl.bin):
#   base port 300h, control block 308h (XT2IDE of the chipset), device XT-IDE rev 1, master and slave
#   detected; padded to 12 KB (the size byte says 24 x 512), the checksum in the last byte.
# The ROMVARS layout (Inc/RomVars.inc) of r625 and r638 is the same; the device numbers are not:
# XT-IDE rev 1 is 06h in r625 and 08h in r638 (DEVICE_8BIT_JUKO_D16X came in before it).
# Usage: make_xtide_rom.py ide_xtl.bin xtide.rom xtide.hex [device]
import sys
raw = open(sys.argv[1], 'rb').read()
dev = int(sys.argv[4], 0) if len(sys.argv) > 4 else 0x08
b = bytearray(raw) + bytearray(12288 - len(raw))
assert b[0:2] == b'\x55\xaa' and b[2] == 24
b[0x4E:0x50] = (0x300).to_bytes(2, 'little')   # IDEVARS.wBasePort
b[0x50:0x52] = (0x308).to_bytes(2, 'little')   # IDEVARS.wControlBlockPort
b[0x52] = dev                                  # IDEVARS.bDevice
b[0x54] = 0x1D                                 # drvParamsMaster.wFlags: auto translate, block mode, no write cache
b[0x5A] = 0x1D                                 # drvParamsSlave.wFlags: the same, detected (not 9Dh)
b[-1] = 0
b[-1] = (-sum(b)) % 256
open(sys.argv[2], 'wb').write(b)
open(sys.argv[3], 'w').write(' '.join('%02X' % x for x in b))
