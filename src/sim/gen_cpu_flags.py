#!/usr/bin/env python3
# Builds the program of tb_cpu_flags.v: ADD / ADC / SUB / SBB, byte and word, immediate and
# register forms, each followed by PUSHF; writes build/cpu_flags_rom.hex (64 KB at F0000) and
# build/cpu_flags_exp.hex (the expected flags, CF PF AF ZF SF OF, one word per test).
import os

os.makedirs('build', exist_ok=True)
MASK = 0x08D5  # OF SF ZF AF PF CF


def flags(op, a, b, cin, w):
    bits = 16 if w else 8
    m = (1 << bits) - 1
    sign = 1 << (bits - 1)
    c = cin if op in ('adc', 'sbb') else 0
    if op in ('add', 'adc'):
        full = a + b + c
        r = full & m
        cf = full > m
        of = (~(a ^ b) & (a ^ r) & sign) != 0
        af = ((a & 0xF) + (b & 0xF) + c) > 0xF
    else:
        full = a - b - c
        r = full & m
        cf = full < 0
        of = ((a ^ b) & (a ^ r) & sign) != 0
        af = ((a & 0xF) - (b & 0xF) - c) < 0
    pf = bin(r & 0xFF).count('1') % 2 == 0
    zf = r == 0
    sf = (r & sign) != 0
    return cf | pf << 2 | af << 4 | zf << 6 | sf << 7 | of << 11


IMM8 = {'add': 0x04, 'adc': 0x14, 'sub': 0x2C, 'sbb': 0x1C}
IMM16 = {'add': 0x05, 'adc': 0x15, 'sub': 0x2D, 'sbb': 0x1D}
REG8 = {'add': 0x00, 'adc': 0x10, 'sub': 0x28, 'sbb': 0x18}  # op AL,BL: modrm D8
REG16 = {'add': 0x01, 'adc': 0x11, 'sub': 0x29, 'sbb': 0x19}  # op AX,BX

vals8 = [(0x7F, 0x01), (0x80, 0xFF), (0x80, 0x01), (0x7F, 0xFF), (0x40, 0x40), (0xC0, 0xC0),
         (0x00, 0x00), (0xFF, 0xFF), (0x7F, 0x00), (0x80, 0x00), (0x7F, 0x80), (0x12, 0x34)]
vals16 = [(0x7FFF, 0x0001), (0x8000, 0xFFFF), (0x8000, 0x0001), (0x7FFF, 0xFFFF), (0x4000, 0x4000),
          (0xC000, 0xC000), (0x0000, 0x0000), (0xFFFF, 0xFFFF), (0x7FFF, 0x0000), (0x8000, 0x0000),
          (0x7FFF, 0x8000), (0x1234, 0x5678)]

# CLI; XOR AX,AX; MOV SS,AX; MOV DS,AX; MOV SP,1000h
code = [0xFA, 0x31, 0xC0, 0x8E, 0xD0, 0x8E, 0xD8, 0xBC, 0x00, 0x10]
exp = []
for w, vals in ((0, vals8), (1, vals16)):
    for op in ('add', 'adc', 'sub', 'sbb'):
        for cin in (0, 1):
            for a, b in vals:
                for form in ('imm', 'reg'):
                    code.append(0xF9 if cin else 0xF8)  # STC / CLC
                    if w:
                        code += [0xB8, a & 0xFF, a >> 8]  # MOV AX,a
                        if form == 'imm':
                            code += [IMM16[op], b & 0xFF, b >> 8]
                        else:
                            code += [0xBB, b & 0xFF, b >> 8, REG16[op], 0xD8]
                    else:
                        code += [0xB0, a]  # MOV AL,a
                        if form == 'imm':
                            code += [IMM8[op], b]
                        else:
                            code += [0xB3, b, REG8[op], 0xD8]
                    code.append(0x9C)  # PUSHF
                    exp.append((flags(op, a, b, cin, w), f'{op}{16 if w else 8} {form} {a:x},{b:x} c={cin}'))
code += [0xC6, 0x06, 0x00, 0x20, 0x55, 0xF4]  # MOV byte [2000h],55h (done); HLT
assert len(code) < 0xFF00 and len(exp) * 2 < 0x1000 - 0x100

rom = [0xFF] * 0x10000
rom[:len(code)] = code
rom[0xFFF0:0xFFF5] = [0xEA, 0x00, 0x00, 0x00, 0xF0]  # JMP F000:0000
with open('build/cpu_flags_rom.hex', 'w') as f:
    f.write('\n'.join(f'{x:02x}' for x in rom) + '\n')
with open('build/cpu_flags_exp.hex', 'w') as f:
    f.write('\n'.join(f'{e:04x}' for e, _ in exp) + '\n')
with open('build/cpu_flags_names.txt', 'w') as f:
    f.write('\n'.join(n for _, n in exp) + '\n')
print(f'{len(exp)} tests')
