S3_TARGET ?=		s3://$(shell whoami)/
KERNEL_URL ?=		http://ports.ubuntu.com/ubuntu-ports/dists/lucid/main/installer-armel/current/images/versatile/netboot/vmlinuz
MKIMAGE_OPTS ?=		-A arm -O linux -T ramdisk -C none -a 0 -e 0 -n initramfs
DEPENDENCIES ?=		/bin/busybox /usr/sbin/xnbd-client /usr/sbin/ntpdate /lib/arm-linux-gnueabihf/libnss_files.so.2 /lib/arm-linux-gnueabihf/libnss_dns.so.2 /etc/udhcpc/default.script
DOCKER_DEPENDENCIES ?=	armbuild/initrd-dependencies
CMDLINE ?=		ip=dhcp root=/dev/nbd0 nbd.max_parts=8 boot=local nousb noplymouth
QEMU_OPTIONS ?=		-M versatilepb -cpu cortex-a9 -m 256 -no-reboot

HOST_ARCH ?=		$(shell uname -m)

.PHONY: publish_on_s3 qemu dist dist_do dist_teardown all travis

# Phonies
all:	uInitrd

travis:
	bash -n tree/init tree/functions tree/boot-*
	make -n Makefile

qemu:
	$(MAKE) qemu-local-text || $(MAKE) qemu-docker-text

qemu-local-text:	vmlinuz initrd.gz
	qemu-system-arm \
		$(QEMU_OPTIONS) \
		-append "console=ttyAMA0 earlyprink=ttyAMA0 $(CMDLINE)" \
		-kernel ./vmlinuz \
		-initrd ./initrd.gz \
		-nographic -monitor null


qemu-local-vga:	vmlinuz initrd.gz
	qemu-system-arm \
		$(QEMU_OPTIONS) \
		-append "$(CMDLINE)" \
		-kernel ./vmlinuz \
		-initrd ./initrd.gz \
		-monitor stdio


qemu-docker qemu-docker-text:	vmlinuz initrd.gz
	docker run -v $(PWD):/boot -it --rm moul/qemu-user qemu-system-arm \
		$(QEMU_OPTIONS) \
		-append "console=ttyAMA0 earlyprink=ttyAMA0 $(CMDLINE) METADATA_IP=1.2.3.4" \
		-kernel /boot/vmlinuz \
		-initrd /boot/initrd.gz \
		-nographic -monitor null


publish_on_s3:	uInitrd initrd.gz
	for file in $<; do \
	  s3cmd put --acl-public $$file $(S3_TARGET); \
	done

dist:
	$(MAKE) dist_do || $(MAKE) dist_teardown

dist_do:
	-git branch -D dist || true
	git checkout -b dist
	$(MAKE) dependencies.tar.gz uInitrd
	git add -f uInitrd initrd.gz tree dependencies.tar.gz
	git commit -am "dist"
	git push -u origin dist -f
	$(MAKE) dist_teardown

dist_teardown:
	git checkout master


# Files
vmlinuz:
	-rm -f $@ $@.tmp
	wget -O $@.tmp $(KERNEL_URL)
	mv $@.tmp $@


uInitrd:	initrd.gz
	$(MAKE) uInitrd-local || $(MAKE) uInitrd-docker
	touch $@


uInitrd-local:	initrd.gz
	mkimage $(MKIMAGE_OPTS) -d initrd.gz uInitrd


uInitrd-docker:	initrd.gz
	docker run \
		-it --rm \
		-v /Users/moul/Git/github/initrd:/host \
		-w /tmp \
		moul/u-boot-tools \
		/bin/bash -xec \
		' \
		  cp /host/initrd.gz . && \
		  mkimage -A arm -O linux -T ramdisk -C none -a 0 -e 0 -n initramfs -d ./initrd.gz ./uInitrd && \
		  cp uInitrd /host/ \
		'


tree/usr/bin/oc-metadata:
	mkdir -p $(shell dirname $@)
	wget https://raw.githubusercontent.com/online-labs/ocs-scripts/master/skeleton/usr/local/bin/oc-metadata -O $@
	chmod +x $@


tree/usr/sbin/@xnbd-client.link:	tree/usr/sbin/xnbd-client
	ln -sf $(<:tree%=%) $(@:%.link=%)
	touch $@


tree/bin/sh:	tree/bin/busybox
	ln -s busybox $@


initrd.gz:	$(addprefix tree/, $(DEPENDENCIES)) $(wildcard tree/*) tree/bin/sh tree/usr/bin/oc-metadata tree/usr/sbin/@xnbd-client.link Makefile
	find tree \( -name "*~" -or -name ".??*~" -or -name "#*#" -or -name ".#*" \) -delete
	cd tree && find . -print0 | cpio --null -o --format=newc | gzip -9 > $(PWD)/$@


$(addprefix tree/, $(DEPENDENCIES)):	dependencies.tar.gz
	tar -m -C tree/ -xzf $<


dependencies.tar.gz:	dependencies/Dockerfile
	$(MAKE) dependencies.tar.gz-armhf || $(MAKE) dependencies.tar.gz-dist
	tar tvzf $@ | grep bin/busybox || rm -f $@
	@test -f $@ || echo $@ is broken
	@test -f $@ || exit 1


dependencies.tar.gz-armhf:
	test $(HOST_ARCH) = armv7l
	docker build -q -t $(DOCKER_DEPENDENCIES) ./dependencies/
	docker run -it $(DOCKER_DEPENDENCIES) export-assets $(DEPENDENCIES)
	docker cp `docker ps -lq`:/tmp/dependencies.tar $(PWD)/
	docker rm `docker ps -lq`
	rm -f dependencies.tar.gz
	gzip dependencies.tar


dependencies.tar.gz-dist:
	wget https://github.com/online-labs/initrd/raw/dist/dependencies.tar.gz
