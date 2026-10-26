/* glassine-reboot [recovery|bootloader|edl|<reason>]
 * reboot(2) with a reason string. busybox `reboot` cannot pass one.
 * The kernel's reboot-mode driver hands the reason to the bootloader; which
 * reason boots which slot is the board's (board.conf TEST_REBOOT_REASON).
 * Syncs first; does not stop services (run from an orderly shutdown or accept that). */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <linux/reboot.h>

int main(int argc, char **argv)
{
    const char *why = argc > 1 ? argv[1] : NULL;
    sync();
    if (why && *why)
        syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
                LINUX_REBOOT_CMD_RESTART2, why);
    else
        syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
                LINUX_REBOOT_CMD_RESTART, NULL);
    perror("reboot");
    return 1;
}
