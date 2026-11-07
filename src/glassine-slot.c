/* glassine-slot: the boot slot in the GPT attributes of boot_a/boot_b, the
 * scheme of Qualcomm's bootloader (ABL). On a GlassineOS dual-boot device the
 * slots are two systems (e.g. A = Android, B = GlassineOS), and the bootloader's
 * tries are the fallback between them: a slot that never gets marked
 * successful runs out of tries and the bootloader boots the other one, if that
 * one is successful (docs/boot.md#slots).
 *
 *   glassine-slot [OPTIONS] status [--porcelain]
 *   glassine-slot [OPTIONS] set-active a|b [--successful]
 *                                                boot this slot next: 7 tries, not
 *                                                successful yet (the bootloader's
 *                                                own set_active); the other slot
 *                                                keeps its state, priority 2.
 *                                                --successful: marked successful
 *                                                at once, for a system that can't
 *                                                mark itself (no tries counted)
 *   glassine-slot [OPTIONS] mark-successful [a|b] the booted slot (default) works:
 *                                                no more tries counted (tries back
 *                                                to 7); no write if it already is
 *   glassine-slot [OPTIONS] reset-tries [a|b]     not successful again, 7 tries
 *                                                (after a kernel update in that slot)
 * OPTIONS: --disk DEV (default: the disk holding boot_a), --sector-size N (for
 * an image file; default 512, a block device says its own).
 * The booted slot is androidboot.slot_suffix in /proc/cmdline
 * (GLASSINE_SLOT_CMDLINE for the host test).
 *
 * Only the attribute words of boot_a and boot_b change; anything else that
 * would differ is a refusal. Both GPT copies are written, the backup first
 * (the bootloader reads the primary; a cut between the two leaves the old
 * state there), each followed by fsync, then both are read back.
 *
 * Exit: 0 done (or nothing to change), 1 I/O failed, 2 usage, 3 refused (no
 * valid GPT, the copies differ beyond the slot attributes, no boot_a/boot_b,
 * the booted slot unknown), 6 busy (another glassine-slot holds the disk). */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#include <linux/fs.h>

#define PRIO_SHIFT 48
#define PRIO_MASK (3ULL << PRIO_SHIFT)
#define ACTIVE (1ULL << 50)
#define TRIES_SHIFT 51
#define TRIES_MASK (7ULL << TRIES_SHIFT)
#define SUCCESS (1ULL << 54)
#define UNBOOTABLE (1ULL << 55)
#define MAX_TRIES 7ULL

struct gpt {
    uint8_t *hdr;       /* the whole header sector */
    uint8_t *arr;       /* the entry array */
    uint64_t my_lba, alt_lba, arr_lba;
    uint32_t hdr_size, nent, esize, arr_bytes;
};

static int fd = -1;
static unsigned ssz = 512;

static uint32_t crc32(const uint8_t *p, size_t n)
{
    uint32_t c = 0xffffffff;
    while (n--) {
        c ^= *p++;
        for (int k = 0; k < 8; k++)
            c = (c >> 1) ^ (0xedb88320 & -(c & 1));
    }
    return ~c;
}

static uint32_t le32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t le64(const uint8_t *p) { return le32(p) | (uint64_t)le32(p + 4) << 32; }
static void put32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = v >> (8 * i); }
static void put64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = v >> (8 * i); }

static int die(int code, const char *msg)
{
    fprintf(stderr, "glassine-slot: %s\n", msg);
    exit(code);
}

static int rd(void *buf, size_t n, uint64_t lba)
{
    return pread(fd, buf, n, (off_t)(lba * ssz)) == (ssize_t)n ? 0 : -1;
}

static int wr(const void *buf, size_t n, uint64_t lba)
{
    return pwrite(fd, buf, n, (off_t)(lba * ssz)) == (ssize_t)n ? 0 : -1;
}

static uint32_t hdr_crc(const struct gpt *g)
{
    uint8_t h[512];
    memcpy(h, g->hdr, g->hdr_size);
    put32(h + 16, 0);
    return crc32(h, g->hdr_size);
}

/* read and check the header at lba and its entry array; 0 = valid */
static int load(struct gpt *g, uint64_t lba)
{
    memset(g, 0, sizeof(*g));
    g->hdr = malloc(ssz);
    if (!g->hdr || rd(g->hdr, ssz, lba))
        return -1;
    if (memcmp(g->hdr, "EFI PART", 8))
        return -1;
    g->hdr_size = le32(g->hdr + 12);
    g->my_lba = le64(g->hdr + 24);
    g->alt_lba = le64(g->hdr + 32);
    g->arr_lba = le64(g->hdr + 72);
    g->nent = le32(g->hdr + 80);
    g->esize = le32(g->hdr + 84);
    if (g->hdr_size < 92 || g->hdr_size > ssz || g->hdr_size > 512 || g->my_lba != lba ||
        g->esize != 128 || g->nent == 0 || g->nent > 1024 || hdr_crc(g) != le32(g->hdr + 16))
        return -1;
    g->arr_bytes = g->nent * g->esize;
    /* whole sectors: the array is written back sector-aligned */
    size_t n = (g->arr_bytes + ssz - 1) / ssz * ssz;
    g->arr = calloc(1, n);
    if (!g->arr || rd(g->arr, n, g->arr_lba))
        return -1;
    return crc32(g->arr, g->arr_bytes) == le32(g->hdr + 88) ? 0 : -1;
}

/* the entry named name (UTF-16LE), -1 none, -2 more than one */
static int find(const uint8_t *arr, uint32_t nent, const char *name)
{
    int found = -1;
    for (uint32_t i = 0; i < nent; i++) {
        const uint8_t *e = arr + i * 128;
        static const uint8_t zero[16];
        if (!memcmp(e, zero, 16))
            continue;
        size_t k = 0;
        for (; name[k]; k++)
            if (e[56 + 2 * k] != (uint8_t)name[k] || e[57 + 2 * k])
                break;
        if (name[k] || k >= 36 || e[56 + 2 * k] || e[57 + 2 * k])
            continue;
        if (found >= 0)
            return -2;
        found = (int)i;
    }
    return found;
}

static uint64_t prio(uint64_t a) { return (a & PRIO_MASK) >> PRIO_SHIFT; }
static uint64_t tries(uint64_t a) { return (a & TRIES_MASK) >> TRIES_SHIFT; }

/* the slot the bootloader boots next (0 a, 1 b, -1 none): GetActiveSlot +
 * FindBootableSlot + HandleActiveSlotUnbootable of ABL */
static int next_slot(const uint64_t at[2])
{
    int s = -1;
    uint64_t best = 0;
    for (int i = 0; i < 2; i++)
        if ((at[i] & ACTIVE) && prio(at[i]) > best)
            best = prio(at[i]), s = i;
    if (s < 0)
        s = 0;  /* first boot: slot a */
    if (!(at[s] & UNBOOTABLE) && ((at[s] & SUCCESS) || tries(at[s]) > 0))
        return s;
    if (!(at[!s] & UNBOOTABLE) && (at[!s] & SUCCESS))
        return !s;
    return -1;
}

static int booted_slot(void)
{
    const char *path = getenv("GLASSINE_SLOT_CMDLINE");
    char buf[4096];
    FILE *f = fopen(path ? path : "/proc/cmdline", "r");
    if (!f)
        return -1;
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = 0;
    for (char *t = strtok(buf, " \t\n"); t; t = strtok(NULL, " \t\n")) {
        if (!strcmp(t, "androidboot.slot_suffix=_a"))
            return 0;
        if (!strcmp(t, "androidboot.slot_suffix=_b"))
            return 1;
    }
    return -1;
}

/* the whole disk that holds the partition named boot_a */
static char *default_disk(void)
{
    static const char *links[] = { "/dev/block/by-name/boot_a", "/dev/disk/by-partlabel/boot_a" };
    static char out[PATH_MAX];
    for (unsigned i = 0; i < 2; i++) {
        struct stat st;
        char sys[PATH_MAX], real[PATH_MAX];
        if (stat(links[i], &st) || !S_ISBLK(st.st_mode))
            continue;
        snprintf(sys, sizeof(sys), "/sys/dev/block/%u:%u/..", major(st.st_rdev), minor(st.st_rdev));
        if (!realpath(sys, real))
            continue;
        const char *base = strrchr(real, '/');
        snprintf(out, sizeof(out), "/dev/%s", base ? base + 1 : real);
        return out;
    }
    return NULL;
}

static void show(const char *name, uint64_t a, int porcelain)
{
    if (!porcelain)
        printf("slot %s: 0x%016llx\n", name, (unsigned long long)a);
    if (porcelain)
        printf("slot=%s\tpriority=%llu\tactive=%d\ttries=%llu\tsuccessful=%d\tunbootable=%d\n", name,
               (unsigned long long)prio(a), !!(a & ACTIVE), (unsigned long long)tries(a),
               !!(a & SUCCESS), !!(a & UNBOOTABLE));
    else
        printf("slot %s: priority %llu%s, %llu tries, %s%s\n", name, (unsigned long long)prio(a),
               a & ACTIVE ? " (active)" : "", (unsigned long long)tries(a),
               a & SUCCESS ? "successful" : "not successful", a & UNBOOTABLE ? ", unbootable" : "");
}

static void usage(void)
{
    die(2, "usage: glassine-slot [--disk DEV] [--sector-size N] status [--porcelain] | "
           "set-active a|b [--successful] | mark-successful [a|b] | reset-tries [a|b]");
}

static int slot_arg(const char *s)
{
    if (!strcmp(s, "a"))
        return 0;
    if (!strcmp(s, "b"))
        return 1;
    usage();
    return -1;
}

/* a test cut: stop with exit 1 after this step (GLASSINE_SLOT_TEST_CUT; its
 * value "readback" makes the read-back compare fail instead) */
static void cut(const char *step)
{
    const char *c = getenv("GLASSINE_SLOT_TEST_CUT");
    if (c && !strcmp(c, step))
        die(1, "test cut");
}

int main(int argc, char **argv)
{
    const char *disk = NULL;
    int sector_opt = 0, i = 1;
    for (; i < argc && !strncmp(argv[i], "--", 2); i++) {
        if (!strcmp(argv[i], "--disk") && i + 1 < argc)
            disk = argv[++i];
        else if (!strcmp(argv[i], "--sector-size") && i + 1 < argc)
            sector_opt = atoi(argv[++i]);
        else
            usage();
    }
    if (i >= argc)
        usage();
    const char *cmd = argv[i++];
    int porcelain = 0, target = -1, write_cmd = 1, successful = 0;
    if (!strcmp(cmd, "status")) {
        write_cmd = 0;
        if (i < argc && !strcmp(argv[i], "--porcelain"))
            porcelain = 1, i++;
    } else if (!strcmp(cmd, "set-active")) {
        if (i >= argc)
            usage();
        target = slot_arg(argv[i++]);
        if (i < argc && !strcmp(argv[i], "--successful"))
            successful = 1, i++;
    } else if (!strcmp(cmd, "mark-successful") || !strcmp(cmd, "reset-tries")) {
        if (i < argc)
            target = slot_arg(argv[i++]);
    } else {
        usage();
    }
    if (i != argc)
        usage();

    if (!disk && !(disk = default_disk()))
        die(3, "no boot_a partition found (--disk DEV)");
    fd = open(disk, (write_cmd ? O_RDWR : O_RDONLY) | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "glassine-slot: %s: %s\n", disk, strerror(errno));
        return 1;
    }
    if (flock(fd, (write_cmd ? LOCK_EX : LOCK_SH) | LOCK_NB))
        die(errno == EWOULDBLOCK ? 6 : 1, "the disk is locked by another glassine-slot");
    struct stat st;
    if (fstat(fd, &st))
        die(1, "cannot stat the disk");
    if (S_ISBLK(st.st_mode)) {
        int b;
        if (ioctl(fd, BLKSSZGET, &b))
            die(1, "cannot read the sector size");
        ssz = b;
    } else if (sector_opt) {
        ssz = sector_opt;
    }
    if (ssz < 512 || ssz > 4096 || (ssz & (ssz - 1)))
        die(2, "sector size: 512 to 4096, a power of two");

    uint64_t last;
    if (S_ISBLK(st.st_mode)) {
        uint64_t bytes;
        if (ioctl(fd, BLKGETSIZE64, &bytes))
            die(1, "cannot read the disk size");
        last = bytes / ssz - 1;
    } else {
        last = st.st_size / ssz - 1;
    }

    /* both copies, or one when the other is broken (a cut write): then the
     * valid one is the state and the broken one is rebuilt from it */
    struct gpt pri, bak;
    int p_ok = !load(&pri, 1);
    int b_ok = !load(&bak, p_ok ? pri.alt_lba : last) && bak.alt_lba == 1;
    if (p_ok && b_ok && bak.nent != pri.nent)
        die(3, "the primary and backup GPT differ in size");
    if (!p_ok && !b_ok)
        die(3, "no valid GPT");
    struct gpt *src = p_ok ? &pri : &bak;
    if (!p_ok || !b_ok)
        fprintf(stderr, "glassine-slot: the %s GPT is broken; the %s is used%s\n", p_ok ? "backup" : "primary",
                p_ok ? "primary" : "backup", write_cmd ? " and the other rebuilt from it" : "");
    int ia = find(src->arr, src->nent, "boot_a"), ib = find(src->arr, src->nent, "boot_b");
    if (ia < 0 || ib < 0)
        die(3, ia == -2 || ib == -2 ? "boot_a or boot_b is there twice" : "no boot_a/boot_b: not an A/B disk");
    /* the copies may differ only in the slot attributes (a cut between the two
     * writes): then the primary, which the bootloader reads, is the state */
    for (uint32_t k = 0; p_ok && b_ok && k < pri.arr_bytes; k++) {
        uint32_t e = k / 128, off = k % 128;
        if (pri.arr[k] != bak.arr[k] && !((e == (uint32_t)ia || e == (uint32_t)ib) && off >= 48 && off < 56))
            die(3, "the primary and backup GPT differ beyond the slot attributes");
    }
    /* the broken copy: the valid one's header with the positions swapped. ABL
     * reads and writes the backup as one fixed 16 KiB block of entries (128 of
     * 128 bytes) before the header at the last LBA, whatever the entry count, so
     * a rebuilt backup array starts 16 KiB before its header, or further when
     * the array is larger (UpdatePartitionAttributes, MAX_PARTITION_ENTRIES_SZ) */
    uint32_t arr_secs = (src->arr_bytes + ssz - 1) / ssz;
    uint32_t arr_secs_bak = arr_secs > 16384 / ssz ? arr_secs : 16384 / ssz;
    struct gpt *dst = p_ok ? &bak : &pri;
    if (!p_ok || !b_ok) {
        size_t arr_n = (size_t)arr_secs * ssz;
        uint8_t *h = malloc(ssz), *a = malloc(arr_n);
        if (!h || !a)
            die(1, "out of memory");
        memcpy(h, src->hdr, ssz);
        memcpy(a, src->arr, arr_n);
        *dst = *src;
        dst->hdr = h, dst->arr = a;
        dst->my_lba = src->alt_lba, dst->alt_lba = src->my_lba;
        dst->arr_lba = p_ok ? dst->my_lba - arr_secs_bak : 2;
        put64(h + 24, dst->my_lba);
        put64(h + 32, dst->alt_lba);
        put64(h + 72, dst->arr_lba);
        put32(h + 16, hdr_crc(dst));
        if (dst->arr_lba <= le64(src->hdr + 48) && p_ok)
            die(3, "no room for the backup entries after the last usable LBA");
    }
    uint64_t at[2] = { le64(src->arr + ia * 128 + 48), le64(src->arr + ib * 128 + 48) };
    int booted = booted_slot(), nx = next_slot(at);
    const char *nm[2] = { "a", "b" };
    if (!write_cmd) {
        if (porcelain) {
            printf("booted=%s\nnext=%s\n", booted < 0 ? "" : nm[booted], nx < 0 ? "" : nm[nx]);
        } else {
            printf("booted: %s\nnext boot: %s\n", booted < 0 ? "unknown" : nm[booted],
                   nx < 0 ? "none (no slot is bootable)" : nm[nx]);
        }
        show("a", at[0], porcelain);
        show("b", at[1], porcelain);
        return 0;
    }

    uint64_t nw[2] = { at[0], at[1] };
    if (!strcmp(cmd, "set-active")) {
        uint64_t *t = &nw[target], *o = &nw[!target];
        *t = (*t | PRIO_MASK | ACTIVE | TRIES_MASK) & ~SUCCESS & ~UNBOOTABLE;
        if (successful)
            *t |= SUCCESS;
        *o = (*o & ~PRIO_MASK & ~ACTIVE) | (2ULL << PRIO_SHIFT);
    } else {
        if (target < 0 && (target = booted) < 0)
            die(3, "the booted slot is unknown (no androidboot.slot_suffix): name it");
        uint64_t *t = &nw[target];
        if (!strcmp(cmd, "mark-successful"))
            *t = (*t | SUCCESS | TRIES_MASK) & ~UNBOOTABLE;
        else
            *t = (*t | TRIES_MASK) & ~SUCCESS & ~UNBOOTABLE;
    }
    int same_bak = p_ok && b_ok && !memcmp(pri.arr, bak.arr, pri.arr_bytes);
    if (nw[0] == at[0] && nw[1] == at[1] && same_bak) {
        printf("glassine-slot: %s: nothing to change\n", cmd);
        return 0;
    }

    /* the new array: the valid copy's (the primary's if both are; a rebuilt
     * primary holds the backup's) with the two attribute words replaced */
    put64(pri.arr + ia * 128 + 48, nw[0]);
    put64(pri.arr + ib * 128 + 48, nw[1]);
    uint32_t acrc = crc32(pri.arr, pri.arr_bytes);
    size_t arr_n = (pri.arr_bytes + ssz - 1) / ssz * ssz;
    /* the bytes after the array in its last sector stay as they are on disk */
    uint8_t *bak_arr = malloc(arr_n);
    if (!bak_arr)
        die(1, "out of memory");
    memcpy(bak_arr, bak.arr, arr_n);
    memcpy(bak_arr, pri.arr, pri.arr_bytes);
    put32(bak.hdr + 88, acrc);
    put32(bak.hdr + 16, hdr_crc(&bak));
    put32(pri.hdr + 88, acrc);
    put32(pri.hdr + 16, hdr_crc(&pri));

    if (wr(bak_arr, arr_n, bak.arr_lba))
        die(1, "writing the backup entries failed");
    cut("backup-array");
    if (wr(bak.hdr, ssz, bak.my_lba) || fsync(fd))
        die(1, "writing the backup header failed");
    cut("backup");
    if (wr(pri.arr, arr_n, pri.arr_lba))
        die(1, "writing the primary entries failed");
    cut("primary-array");
    if (wr(pri.hdr, ssz, 1) || fsync(fd))
        die(1, "writing the primary header failed");

    /* read back: both copies valid, equal, with the new attributes. From the
     * disk, not the page cache: drop the cached blocks first */
    if (S_ISBLK(st.st_mode) ? ioctl(fd, BLKFLSBUF, 0) : posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED))
        die(1, "cannot drop the cached blocks before the read-back");
    struct gpt p2, b2;
    const char *c = getenv("GLASSINE_SLOT_TEST_CUT");
    if (c && !strcmp(c, "readback"))  /* the test of the mismatch path */
        put64(pri.arr + ia * 128 + 48, ~nw[0]);
    if (load(&p2, 1) || load(&b2, p2.alt_lba) || memcmp(p2.arr, pri.arr, pri.arr_bytes) ||
        memcmp(b2.arr, pri.arr, pri.arr_bytes))
        die(1, "read-back mismatch after the write");
    at[0] = nw[0], at[1] = nw[1];
    nx = next_slot(at);
    printf("glassine-slot: %s done; next boot: %s\n", cmd, nx < 0 ? "none" : nm[nx]);
    return 0;
}
