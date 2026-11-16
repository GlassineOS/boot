#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The loader's reading of the boot partition's raw form, ported from GlassineOS/loader
core/src/raw.rs (parse_table, Raw::new, region, read_image, check_header) and
core/src/gspl.rs (parse, its checks before the decoding), so the tests judge what
glassine-boot-raw and lib/glassine-bootpart.sh write by the loader's rules. The loader
record's slots are read by ../bootpart/loader_model.py (record.rs).

  raw_model.py table IMG               primary|backup, then "name off size flags"; 1: none
  raw_model.py item IMG NAME           the region's item to stdout (loader: the image;
                                       splash regions: the file; record: the record
                                       in use, "slot seq both" first); 1: none
  raw_model.py seed IMG A B            slot files A and B (or -: zeros) into the record
  raw_model.py next IMG K=V...         the loader's own write (record.rs next)
  raw_model.py replay IMG0 TRACE NAME  every cut of the write sequence in TRACE (the
                                       library's GLASSINE_BI_RAW_TRACE) over IMG0, at
                                       every byte: the item NAME (or "table") read is
                                       the old one, none, or the new one; the whole
                                       sequence gives the new one. Prints the counts
  raw_model.py state IMG0 TRACE K OUT  IMG0 with the first K bytes of TRACE's writes
  raw_model.py splash OUT W H [KIND]   a format-2 grey8 picture (or kind 1: leave
                                       the screen) for the tests
"""
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'bootpart'))
import loader_model as lm  # noqa: E402

TABLE = 4096
SLOT = 16384
LOADER_MAX = (3 << 20) - 4096


def crc(b):
    return zlib.crc32(b) & 0xFFFFFFFF


def u32(b, o):
    return struct.unpack_from('<I', b, o)[0]


def u64(b, o):
    return struct.unpack_from('<Q', b, o)[0]


def good_name(n):
    return 1 <= len(n) <= 31 and all(c in b'abcdefghijklmnopqrstuvwxyz0123456789-' for c in n)


def parse_table(b, part):
    if len(b) < TABLE:
        return None
    b = b[:TABLE]
    if b[0:8] != b'GLREGION' or crc(b[:4092]) != u32(b, 4092) or u32(b, 8) != 1:
        return None
    if u64(b, 16) != part or part < 2 * TABLE:
        return None
    n = u32(b, 12)
    if n == 0 or n > 62:
        return None
    if any(b[24:64]) or any(b[64 + 64 * n:4092]):
        return None
    end = part - TABLE
    out = []
    for i in range(n):
        e = b[64 + 64 * i:128 + 64 * i]
        ln = e[:32].find(0)
        ln = 32 if ln < 0 else ln
        off, size, flags = u64(e, 32), u64(e, 40), u32(e, 48)
        ok = (crc(e[:52]) == u32(e, 52) and not any(e[56:64]) and good_name(e[:ln]) and not any(e[ln:32])
              and off % 4096 == 0 and size % 4096 == 0 and size > 0 and off >= TABLE and off + size <= end)
        if not ok:
            return None
        name = e[:ln].decode()
        if any(r[0] == name or (off < r[1] + r[2] and r[1] < off + size) for r in out):
            return None
        out.append((name, off, size, flags))
    return out


def table(img):
    part = len(img)
    for copy, off in (('primary', 0), ('backup', part - TABLE)):
        t = parse_table(img[off:off + TABLE], part)
        if t is not None:
            return copy, t
    return None


def region(img, name):
    t = table(img)
    if t is None:
        return None
    for n, off, size, flags in t[1]:
        if n == name and flags == 0:
            return off, size
    return None


def check_header(h, size):
    if len(h) < 32 or h[0:8] != b'GLLOADER' or crc(h[0:28]) != u32(h, 28) or u32(h, 8) != 1 or u32(h, 12) != 0:
        return None
    n = u64(h, 16)
    if n == 0 or n > LOADER_MAX or 4096 + n > size:
        return None
    return n, u32(h, 24)


def gspl_ok(b):
    """gspl.rs parse, every check before the decoding"""
    if len(b) < 64 or b[0:8] != b'GLSPLASH' or crc(b[0:52]) != u32(b, 52):
        return False
    if struct.unpack_from('<H', b, 8)[0] not in (1, 2):
        return False
    kind = struct.unpack_from('<H', b, 10)[0]
    if kind == 1:
        return not any(b[12:52]) and len(b) == 64
    if kind != 0 or u64(b, 40) != len(b) - 64:
        return False
    return crc(b[64:]) == u32(b, 48)


def item(img, name):
    r = region(img, name)
    if r is None:
        return None
    off, size = r
    if name == 'record':
        if size < 2 * SLOT:
            return None
        u = lm_in_use(img[off:off + SLOT], img[off + SLOT:off + 2 * SLOT])
        if u is None:
            return None
        return ('%s %d %d\n' % ('ab'[u[0]], u[1], int(u[3])) + ''.join(f'{k}={v}\n' for k, v in u[2])).encode()
    if name == 'loader':
        h = check_header(img[off:off + 4096], size)
        if h is None:
            return None
        image = img[off + 4096:off + 4096 + h[0]]
        return bytes(image) if crc(image) == h[1] else None
    if name in ('splash-default', 'splash', 'override'):
        head = img[off:off + 64]
        if head[0:8] != b'GLSPLASH':
            return None
        ln = u64(head, 40) + 64
        if ln > size:
            return None
        f = bytes(img[off:off + ln])
        return f if gspl_ok(f) else None
    return None


def lm_in_use(a, b):
    def rd(x):
        try:
            return lm.read_slot(bytes(x))
        except lm.Bad:
            return None
    ra, rb = rd(a), rd(b)
    if ra and rb:
        return (1, rb[0], rb[1], True) if rb[0] > ra[0] else (0, ra[0], ra[1], True)
    if ra:
        return (0, ra[0], ra[1], False)
    if rb:
        return (1, rb[0], rb[1], False)
    return None


def judge(img, name):
    if name == 'table':
        t = table(img)
        return None if t is None else repr(t[1]).encode()
    if name == 'record':
        # the record in use, without the slot and both-valid line: old or new
        x = item(img, 'record')
        return None if x is None else x.split(b'\n', 1)[1]
    return item(img, name)


def trace(d):
    n = 1
    out = []
    while os.path.exists(os.path.join(d, '%d.off' % n)):
        with open(os.path.join(d, '%d.off' % n)) as f:
            off = int(f.read())
        with open(os.path.join(d, '%d.bin' % n), 'rb') as f:
            out.append((off, f.read()))
        n += 1
    return out


def state(img0, writes, k):
    img = bytearray(img0)
    for off, b in writes:
        if k <= 0:
            break
        m = min(k, len(b))
        img[off:off + m] = b[:m]
        k -= m
    return img


def main(a):
    if a[0] == 'table':
        t = table(open(a[1], 'rb').read())
        if t is None:
            return 1
        print(t[0])
        for r in t[1]:
            print(*r)
    elif a[0] == 'item':
        x = item(open(a[1], 'rb').read(), a[2])
        if x is None:
            return 1
        sys.stdout.buffer.write(x)
    elif a[0] == 'seed':
        with open(a[1], 'r+b') as f:
            img = f.read()
            off, _ = region(img, 'record')
            for i, p in enumerate(a[2:4]):
                f.seek(off + i * SLOT)
                f.write(b'\0' * SLOT if p == '-' else open(p, 'rb').read())
    elif a[0] == 'next':
        with open(a[1], 'r+b') as f:
            img = f.read()
            off, _ = region(img, 'record')
            u = lm_in_use(img[off:off + SLOT], img[off + SLOT:off + 2 * SLOT])
            if u is None:
                return 1
            rec = list(u[2])
            for kv in [f'seq={u[1] + 1}'] + a[2:]:
                k, v = kv.split('=', 1)
                for n, (x, _) in enumerate(rec):
                    if x == k:
                        rec[n] = (k, v)
                        break
                else:
                    rec.append((k, v))
            b = lm.text(rec).encode()
            f.seek(off + (1 - u[0]) * SLOT)
            f.write(b + b'\n' * (SLOT - len(b)))
    elif a[0] == 'replay':
        img0 = open(a[1], 'rb').read()
        writes = trace(a[2])
        name = a[3]
        img = bytearray(img0)
        old = judge(img, name)
        final = state(img0, writes, sum(len(b) for _, b in writes))
        new = judge(final, name)
        cuts = bad = nones = olds = news = 0
        for off, b in writes:
            for i in range(len(b) + 1):
                if i:
                    img[off + i - 1] = b[i - 1]
                got = judge(img, name)
                cuts += 1
                if got == old:
                    olds += 1
                elif got is None:
                    nones += 1
                elif got == new:
                    news += 1
                else:
                    bad += 1
                    if bad <= 3:
                        print('cut at write %d byte %d: neither old, none nor new' % (off, i), file=sys.stderr)
        if img != final:
            print('the replay does not end in the image', file=sys.stderr)
            bad += 1
        print('cuts=%d old=%d none=%d new=%d bad=%d writes=%d final=%s' % (
            cuts, olds, nones, news, bad, len(writes), 'new' if new is not None and new != old else 'same-or-none'))
        return 1 if bad else 0
    elif a[0] == 'state':
        img0 = open(a[1], 'rb').read()
        with open(a[4], 'wb') as f:
            f.write(state(img0, trace(a[2]), int(a[3])))
    elif a[0] == 'splash':
        w, h = int(a[2]), int(a[3])
        kind = int(a[4]) if len(a) > 4 else 0
        if kind == 1:
            hd = bytearray(64)
            hd[0:8] = b'GLSPLASH'
            struct.pack_into('<HH', hd, 8, 2, 1)
        else:
            payload = bytes((x * 31 + y * 7) % 256 for y in range(h) for x in range(w))
            hd = bytearray(64)
            hd[0:8] = b'GLSPLASH'
            struct.pack_into('<HHIIIIII', hd, 8, 2, 0, w, h, w, h, 3, 0xFFFFFF)
            struct.pack_into('<HHQI', hd, 36, 0, 0, len(payload), crc(payload))
        struct.pack_into('<I', hd, 52, crc(bytes(hd[0:52])))
        with open(a[1], 'wb') as f:
            f.write(bytes(hd) + (payload if kind == 0 else b''))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
