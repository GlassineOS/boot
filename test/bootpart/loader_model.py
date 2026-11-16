#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The loader's reading of the boot partition, ported line for line from
GlassineOS/loader core/src/record.rs (parse, read_slot, in_use, next) and
core/src/setrec.rs (parse, check_cmdline), so the tests judge what
lib/glassine-bootpart.sh writes by the loader's rules, not by its own.

  loader_model.py in-use DIR          slot seq both_valid, then the record's lines
  loader_model.py get DIR KEY         KEY of the record in use (exit 1: no record)
  loader_model.py set-ok DIR ID SHA   the set ID checks as the loader checks it
  loader_model.py next DIR K=V...     the loader's own write (record.rs next) to
                                      the other slot
  loader_model.py slot FILE           seq of a slot file, or exit 1 (not valid)
  loader_model.py board-archive CONF  the installer's board_archive (pc_boot.rs)
"""
import hashlib
import os
import sys

SLOT_BYTES = 16384
CMDLINE_MAX = 1920


class Bad(Exception):
    pass


def sha(b):
    return hashlib.sha256(b).hexdigest()


def parse(b):
    try:
        text = b.decode('utf-8')
    except UnicodeDecodeError:
        raise Bad('not utf-8')
    if not text.endswith('\n') or '\r' in text:
        raise Bad('not lines')
    i = text[:-1].rfind('\n')
    body_end = i + 1 if i >= 0 else 0
    body, last = text[:body_end], text[body_end:]
    if not last.startswith('check='):
        raise Bad('no check line')
    if last[len('check='):-1] != sha(body.encode()):
        raise Bad('check mismatch')
    lines = []
    for n, line in enumerate(body.split('\n')[:-1] if body else []):
        if '=' not in line:
            raise Bad('not key=value')
        k, v = line.split('=', 1)
        if not k:
            raise Bad('not key=value')
        if any(x == k for x, _ in lines):
            raise Bad('duplicate key')
        if n == 0 and line != 'format=1':
            raise Bad('not format 1')
        lines.append((k, v))
    if not lines:
        raise Bad('empty')
    return lines


def get(rec, key):
    for k, v in rec:
        if k == key:
            return v
    return ''


def read_slot(b):
    end = len(b)
    while end > 0 and b[end - 1] == 0x0A:
        end -= 1
    if end == 0:
        raise Bad('empty')
    if end == len(b):
        raise Bad('not lines')
    try:
        rec = parse(b[:end + 1])
    except Bad as e:
        raise Bad('trailing bytes' if str(e) == 'no check line' else str(e))
    s = get(rec, 'seq')
    if not s or not s.isdigit() or not s.isascii():
        raise Bad('no seq')
    n = int(s)
    if n >= 1 << 64:
        raise Bad('no seq')
    return n, rec


def slot_bytes(path):
    try:
        with open(path, 'rb') as f:
            return f.read()
    except OSError:
        return None


def in_use(d):
    ra = rb = None
    a = slot_bytes(os.path.join(d, 'glassine', 'loader.a'))
    b = slot_bytes(os.path.join(d, 'glassine', 'loader.b'))
    try:
        ra = read_slot(a) if a is not None else None
    except Bad:
        pass
    try:
        rb = read_slot(b) if b is not None else None
    except Bad:
        pass
    if ra and rb:
        return (1, rb[0], rb[1], True) if rb[0] > ra[0] else (0, ra[0], ra[1], True)
    if ra:
        return (0, ra[0], ra[1], False)
    if rb:
        return (1, rb[0], rb[1], False)
    return None


def text(rec):
    body = ''.join(f'{k}={v}\n' for k, v in rec)
    return body + f'check={sha(body.encode())}\n'


def setrec_ok(d, ident, want_sha):
    p = os.path.join(d, 'glassine', 'sets', ident)
    with open(os.path.join(p, 'set.rec'), 'rb') as f:
        b = f.read()
    if sha(b) != want_sha:
        raise Bad('set.rec is not the one named')
    r = parse(b)
    hexd = set('0123456789abcdef')
    i = get(r, 'id')
    if len(i) != 16 or not set(i) <= hexd or i != ident:
        raise Bad('id')
    for key in ('kernel_sha256', 'initrd_sha256'):
        v = get(r, key)
        if len(v) != 64 or not set(v) <= hexd:
            raise Bad(key)
    for key in ('kernel_size', 'initrd_size'):
        if not get(r, key).isdigit():
            raise Bad(key)
    c = get(r, 'cmdline')
    if len(c.encode()) > CMDLINE_MAX or any(ord(x) < 0x20 or ord(x) == 0x7F for x in c):
        raise Bad('cmdline')
    w = c.split(' ')
    if not any(x.startswith('glassine.system=') for x in w) or not any(x.startswith('glassine.userdata=') for x in w) \
            or not any(x == 'glassine.img=' + i for x in w) or any(x.startswith('glassine.deploy.once=') for x in w):
        raise Bad('cmdline keys')
    for name, sk, zk in (('vmlinuz', 'kernel_sha256', 'kernel_size'), ('initrd', 'initrd_sha256', 'initrd_size')):
        with open(os.path.join(p, name), 'rb') as f:
            data = f.read()
        if len(data) != int(get(r, zk)) or sha(data) != get(r, sk):
            raise Bad(name)


def board_archive(conf):
    out = bytearray()
    for ino, (name, mode, data) in enumerate([('etc', 0o40755, b''), ('etc/glassine-boot', 0o40755, b''),
                                              ('etc/glassine-boot/board.conf', 0o100644, conf), ('TRAILER!!!', 0, b'')]):
        nb = len(name) + 1
        fields = [ino + 1, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, nb, 0]
        out += b'070701' + b''.join(b'%08X' % f for f in fields) + name.encode() + b'\0'
        out += b'\0' * (-len(out) % 4)
        out += data
        out += b'\0' * (-len(out) % 4)
    return bytes(out)


def main(a):
    if a[0] == 'in-use':
        u = in_use(a[1])
        if u is None:
            return 1
        print('ab'[u[0]], u[1], int(u[3]))
        for k, v in u[2]:
            print(f'{k}={v}')
    elif a[0] == 'get':
        u = in_use(a[1])
        if u is None:
            return 1
        print(get(u[2], a[2]))
    elif a[0] == 'set-ok':
        try:
            setrec_ok(a[1], a[2], a[3])
        except (Bad, OSError, ValueError) as e:
            print(e, file=sys.stderr)
            return 1
    elif a[0] == 'next':
        u = in_use(a[1])
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
        b = text(rec).encode()
        b += b'\n' * (SLOT_BYTES - len(b))
        with open(os.path.join(a[1], 'glassine', 'loader.' + 'ba'[u[0]]), 'r+b') as f:
            f.write(b)
    elif a[0] == 'slot':
        try:
            print(read_slot(slot_bytes(a[1]) or b'')[0])
        except Bad:
            return 1
    elif a[0] == 'board-archive':
        with open(a[1], 'rb') as f:
            sys.stdout.buffer.write(board_archive(f.read()))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
