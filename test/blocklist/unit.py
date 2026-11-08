#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""lib/glassine-blocklist's checks for what a real file system can't be made to
produce on demand (the rest is in inner.sh, on real ext4)."""
import importlib.machinery, importlib.util, sys

sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader('gb', sys.argv[1])
spec = importlib.util.spec_from_loader('gb', loader)
gb = importlib.util.module_from_spec(spec)
loader.exec_module(gb)
B = 4096
fails = 0


def ok(name, cond):
    global fails
    print(('ok   ' if cond else 'FAIL ') + name)
    fails += 0 if cond else 1


def refused(fn, *a):
    try:
        fn(*a)
    except gb.Refused:
        return True
    return False


ID = '0123456789abcdef'
SHA = 'ab' * 32
good = [(0, 100 * B, 2 * B, 0), (2 * B, 300 * B, 3 * B, 1)]
ok('two extents: first and count in 4096-byte blocks', gb.check_extents(good, 5 * B) == [(100, 2), (300, 3)])
ok('adjacent extents are merged', gb.check_extents([(0, B, B, 0), (B, 2 * B, B, 1)], 2 * B) == [(1, 2)])
for bit, name in gb.REFUSED_FLAGS.items():
    ok(f'a {name} extent is refused', refused(gb.check_extents, [(0, B, B, bit)], B))
for name, ext, size in [
        ('a hole', [(0, B, B, 0), (2 * B, 9 * B, B, 0)], 3 * B),
        ('a file longer than its extents', [(0, B, B, 0)], 2 * B),
        ('extents longer than the file', [(0, B, 2 * B, 0)], B),
        ('a misaligned physical address', [(0, B + 1, B, 0)], B),
        ('physical address 0', [(0, 0, B, 0)], B),
        ('a size that isn\'t a multiple of 4096', [(0, B, B, 0)], B + 1),
        ('an empty file', [], 0)]:
    ok(f'{name}: refused', refused(gb.check_extents, ext, size))
apart = [(i * B, (2 * i + 1) * B, B, 0) for i in range(248)]
ok('248 extents: accepted', len(gb.check_extents(apart, 248 * B)) == 248)
apart = [(i * B, (2 * i + 1) * B, B, 0) for i in range(249)]
ok('249 extents: refused', refused(gb.check_extents, apart, 249 * B))

ok('an encrypted directory is refused', refused(gb.check_dir_flags, gb.FS_ENCRYPT_FL))
ok('a data-journalled directory is refused', refused(gb.check_dir_flags, gb.FS_JOURNAL_DATA_FL))
ok('a plain directory passes', not refused(gb.check_dir_flags, 0))

ext = [(100, 2), (300, 3)]
rec = gb.encode(ID, 'userdata', 5 * B, SHA, ext)
ok('a record is 4096 bytes', len(rec) == 4096)
d = gb.decode(rec)
ok('encode and decode agree', d == {'id': ID, 'partition': 'userdata', 'size': 5 * B, 'sha256': SHA, 'extents': ext})
full = [(2 * i + 1, 1) for i in range(248)]
ok('248 extents fill the record exactly', gb.decode(gb.encode(ID, 'userdata', 248 * B, SHA, full))['extents'] == full)
ok('all zeros is no record', gb.decode(bytes(4096)) is None)


def poke(off, data):
    r = bytearray(rec)
    r[off:off + len(data)] = data
    return bytes(r)


for name, bad in [
        ('a torn record (cut in the sha256, no extents)', rec[:100] + bytes(3996)),
        ('bad magic', poke(0, b'X')),
        ('a newer format', poke(8, b'\2')),
        ('extent_count 0', poke(12, b'\0')),
        ('extent_count 249', poke(12, b'\xf9')),
        ('an image id that isn\'t hex', poke(16, b'Z')),
        ('reserved bytes set', poke(110, b'\1')),
        ('a size that disagrees with the extents', poke(64, b'\0\x70')),
        ('bytes after the last extent', poke(4000, b'\1')),
        ('a short record', rec[:4095])]:
    ok(f'decode: {name}: refused', refused(gb.decode, bad))
for name, a in [
        ('an id that isn\'t 16 hex digits', ('xyz', 'userdata', B, SHA, [(1, 1)])),
        ('a sha that isn\'t 64 hex digits', (ID, 'userdata', B, 'ab', [(1, 1)])),
        ('a partition name over 31 bytes', (ID, 'u' * 32, B, SHA, [(1, 1)])),
        ('no extents', (ID, 'userdata', B, SHA, [])),
        ('extents that don\'t add up', (ID, 'userdata', 2 * B, SHA, [(1, 1)]))]:
    ok(f'encode: {name}: refused', refused(gb.encode, *a))
sys.exit(1 if fails else 0)
