#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""A simulated bootloader reader (specs/005, FR-013). It follows the list in
docs/blocklist.md, "The bootloader accepts a record only if", and shares no
code with lib/glassine-blocklist, so a mistake in the writer can't hide here.

usage: reader.py SLOT USERDATA OUT
SLOT is the default slot, USERDATA the partition the extents are in.
exit 0: OUT holds the image. exit 1: rejected, the default slot boots.
"""
import hashlib, mmap, os, struct, sys


def reject(why):
    print(f'reject: {why}')
    sys.exit(1)


def read_direct(fd, off, n):
    buf = mmap.mmap(-1, n)
    if os.preadv(fd, [buf], off) != n:
        reject(f'short read at {off}')
    return bytes(buf)


slot, part, out = sys.argv[1:]
sfd = os.open(slot, os.O_RDONLY | os.O_DIRECT)
pfd = os.open(part, os.O_RDONLY | os.O_DIRECT)
slot_size = os.lseek(sfd, 0, os.SEEK_END)
part_blocks = os.lseek(pfd, 0, os.SEEK_END) // 4096

r = read_direct(sfd, slot_size - 65536, 4096)
if r == bytes(4096):
    reject('no record')
if r[:8] != b'GLBLKLST' or struct.unpack_from('<I', r, 8)[0] != 1:
    reject('magic or format')
if r[104:128] != bytes(24):
    reject('reserved bytes')
count = struct.unpack_from('<I', r, 12)[0]
if not 1 <= count <= 248:
    reject('extent_count')
image_size = struct.unpack_from('<Q', r, 64)[0]
if image_size % 4096:
    reject('image_size')
if image_size > slot_size - 65536:
    reject('image_size is past the limit')
total = 0
extents = []
for i in range(count):
    first, blocks = struct.unpack_from('<QQ', r, 128 + 16 * i)
    if first >= part_blocks or blocks > part_blocks - first:
        reject('an extent is outside the partition')
    total += blocks
    extents.append((first, blocks))
if total != image_size // 4096:
    reject('the extents do not add up')
data = b''.join(read_direct(pfd, first * 4096, blocks * 4096) for first, blocks in extents)
if hashlib.sha256(data).digest() != r[72:104]:
    reject('sha256')
with open(out, 'wb') as f:
    f.write(data)
print('accepted')
