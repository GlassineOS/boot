#!/usr/bin/env python3
# A synthetic split-image .mdt for test/seed and test/qemu: an ELF header and its
# program headers, nothing else unless --pad adds bytes after them.
#   mkmdt.py OUT 32|64 [--pad N] SEG...
# SEG = TYPE,FLAGS,OFFSET,FILESZ,MEMSZ (numbers; FLAGS may be 0x...).
import struct
import sys

out, cls, rest = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
pad = 0
if rest[:1] == ['--pad']:
    pad, rest = int(rest[1]), rest[2:]
segs = [[int(x, 0) for x in s.split(',')] for s in rest]
if cls == 32:
    eh, ph = 52, 32
    head = b'\x7fELF\x01\x01\x01' + b'\0' * 9 + struct.pack('<HHIIIIIHHHHHH', 2, 40, 1, 0, eh, 0, 0, eh, ph, len(segs), 0, 0, 0)
    phs = b''.join(struct.pack('<IIIIIIII', t, o, 0, 0, fs, ms, fl, 4) for t, fl, o, fs, ms in segs)
else:
    eh, ph = 64, 56
    head = b'\x7fELF\x02\x01\x01' + b'\0' * 9 + struct.pack('<HHIQQQIHHHHHH', 2, 183, 1, 0, eh, 0, 0, eh, ph, len(segs), 0, 0, 0)
    phs = b''.join(struct.pack('<IIQQQQQQ', t, fl, o, 0, 0, fs, ms, 4) for t, fl, o, fs, ms in segs)
with open(out, 'wb') as f:
    f.write(head + phs + b'\x5a' * pad)
