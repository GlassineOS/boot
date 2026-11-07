#!/usr/bin/env python3
"""GPT edits for test/slot, written apart from glassine-slot (512-byte sectors).

  gpt.py entries IMG N                  both headers say N entries; the arrays stay where
                                        they are (sgdisk's backup array at last-32, where
                                        ABL keeps it); the CRCs recomputed
  gpt.py field IMG primary|backup OFF SIZE VALUE
                                        a header field (SIZE 4 or 8 bytes), the CRC recomputed
  gpt.py abl-attr IMG NAME HEX          what ABL's UpdatePartitionAttributes does: the
                                        attribute word of NAME in the primary (header at
                                        LBA 1, entries at 2) and in the backup as one fixed
                                        16 KiB block of entries before the last LBA, each
                                        array CRC over its header's entry count, then the
                                        header CRC
"""
import struct
import sys
import zlib

SS = 512
ABL_BLOCK = 16384


def hdr_crc(h):
    size = struct.unpack_from('<I', h, 12)[0]
    b = bytearray(h[:size])
    b[16:20] = b'\0\0\0\0'
    return zlib.crc32(bytes(b)) & 0xffffffff


def last_lba(f):
    f.seek(0, 2)
    return f.tell() // SS - 1


def read(f, lba, n):
    f.seek(lba * SS)
    return bytearray(f.read(n))


def write(f, lba, data):
    f.seek(lba * SS)
    f.write(data)


def fix(f, hlba, arr_lba=None):
    """recompute the array CRC (from the header's own array position unless given) and the header CRC"""
    h = read(f, hlba, SS)
    nent, esize = struct.unpack_from('<II', h, 80)
    if arr_lba is None:
        arr_lba = struct.unpack_from('<Q', h, 72)[0]
    struct.pack_into('<I', h, 88, zlib.crc32(bytes(read(f, arr_lba, nent * esize))) & 0xffffffff)
    struct.pack_into('<I', h, 16, hdr_crc(h))
    write(f, hlba, h)


def main(argv):
    cmd, img = argv[1], argv[2]
    with open(img, 'r+b') as f:
        last = last_lba(f)
        if cmd == 'entries':
            for hlba in (1, last):
                h = read(f, hlba, SS)
                struct.pack_into('<I', h, 80, int(argv[3]))
                write(f, hlba, h)
                fix(f, hlba)
        elif cmd == 'field':
            hlba = 1 if argv[3] == 'primary' else last
            off, size, val = int(argv[4]), int(argv[5]), int(argv[6], 0)
            h = read(f, hlba, SS)
            struct.pack_into('<I' if size == 4 else '<Q', h, off, val)
            write(f, hlba, h)
            fix(f, hlba)
        elif cmd == 'abl-attr':
            name, attr = argv[3], int(argv[4], 16)
            want = name.encode('utf-16-le')
            for hlba, arr_lba in ((1, 2), (last, last - ABL_BLOCK // SS)):
                nent = struct.unpack_from('<I', read(f, hlba, SS), 80)[0]
                arr = read(f, arr_lba, nent * 128)
                for i in range(nent):
                    e = arr[i * 128:(i + 1) * 128]
                    n = len(want)
                    if bytes(e[56:56 + n]) == want and bytes(e[56 + n:58 + n]) == b'\0\0':
                        struct.pack_into('<Q', arr, i * 128 + 48, attr)
                write(f, arr_lba, arr)
                fix(f, hlba, arr_lba)
        else:
            sys.exit('usage: gpt.py entries|field|abl-attr IMG ...')


if __name__ == '__main__':
    main(sys.argv)
