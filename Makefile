# SPDX-License-Identifier: GPL-2.0-or-later
# make && make DESTDIR=… install     the tools (glassine-reboot: a C compiler + linux-headers)
# make initramfs                    the boot initramfs, inside an arm64 Alpine
#                                   (busybox-static busybox-extras e2fsprogs cpio gzip)
PREFIX ?= /usr
SYSCONFDIR ?= /etc
CC ?= cc
CFLAGS ?= -Os -Wall

all: glassine-reboot

glassine-reboot: src/glassine-reboot.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

initramfs: initramfs.cpio.gz
initramfs.cpio.gz: initramfs/init build-initramfs.sh lib/glassine-state.sh lib/glassine-root.sh
	sh build-initramfs.sh $@

install: glassine-reboot
	install -Dm755 sbin/glassine-bootimg $(DESTDIR)$(PREFIX)/sbin/glassine-bootimg
	install -Dm755 sbin/glassine-deploy $(DESTDIR)$(PREFIX)/sbin/glassine-deploy
	install -Dm755 sbin/glassine $(DESTDIR)$(PREFIX)/sbin/glassine
	ln -sf glassine $(DESTDIR)$(PREFIX)/sbin/apk
	install -Dm755 sbin/glassine-switch-hook $(DESTDIR)$(PREFIX)/sbin/glassine-switch-hook
	install -Dm755 sbin/glassine-hibernate $(DESTDIR)$(PREFIX)/sbin/glassine-hibernate
	install -Dm755 openrc/glassine-switch $(DESTDIR)$(SYSCONFDIR)/init.d/glassine-switch
	install -Dm755 sbin/glassine-deploy-accept $(DESTDIR)$(PREFIX)/sbin/glassine-deploy-accept
	install -Dm755 openrc/glassine-deploy-accept $(DESTDIR)$(SYSCONFDIR)/init.d/glassine-deploy-accept
	install -Dm644 lib/glassine-state.sh $(DESTDIR)$(PREFIX)/lib/glassine-boot/glassine-state.sh
	install -Dm644 lib/glassine-root.sh $(DESTDIR)$(PREFIX)/lib/glassine-boot/glassine-root.sh
	install -Dm644 lib/glassine-accounts.sh $(DESTDIR)$(PREFIX)/lib/glassine-boot/glassine-accounts.sh
	install -Dm644 conf/deploy.conf.example $(DESTDIR)$(PREFIX)/share/glassine-boot/deploy.conf.example
	install -Dm755 sbin/glassine-reboot-clean $(DESTDIR)$(PREFIX)/sbin/glassine-reboot-clean
	install -Dm755 glassine-reboot $(DESTDIR)$(PREFIX)/sbin/glassine-reboot
	install -Dm755 lib/glassine-bootimg-pack $(DESTDIR)$(PREFIX)/lib/glassine-bootimg/glassine-bootimg-pack
	install -Dm755 openrc/glassine-bootimg-promote $(DESTDIR)$(SYSCONFDIR)/init.d/glassine-bootimg-promote
	install -Dm644 conf/board.conf.example $(DESTDIR)$(PREFIX)/share/glassine-bootimg/board.conf.example
	install -d $(DESTDIR)$(SYSCONFDIR)/glassine-bootimg/post-promote.d $(DESTDIR)$(SYSCONFDIR)/glassine-bootimg/post-fail.d $(DESTDIR)$(SYSCONFDIR)/glassine-bootimg/health.d
	[ ! -e initramfs.cpio.gz ] || install -Dm644 initramfs.cpio.gz $(DESTDIR)$(PREFIX)/share/glassine-bootimg/initramfs.cpio.gz

check:
	sh test/bootimg/test.sh
	sh test/initramfs/test.sh
	sh test/deploy/test.sh
	sh test/root/test.sh
	sh test/replay/test.sh

clean:
	rm -f glassine-reboot initramfs.cpio.gz

.PHONY: all initramfs install check clean
