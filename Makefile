DOSFSTOOLS_SRC ?= dosfstools
DESTDIR ?= out

CROSS_COMPILE ?= arm-linux-gnueabi-
CC := $(CROSS_COMPILE)gcc
STRIP ?= $(CROSS_COMPILE)strip
OPT_CFLAGS ?= -mcpu=cortex-a8 -mthumb

all: install

mkfs.fat:
	CC="$(CC)" CFLAGS="-D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64 $(OPT_CFLAGS) $(CFLAGS)" LDFLAGS="-static $(LDFLAGS)" $(MAKE) -C $(DOSFSTOOLS_SRC)
	cp $(DOSFSTOOLS_SRC)/mkfs.fat .

install: mkfs.fat
	mkdir -p $(DESTDIR)
	mkdir -p $(DESTDIR)/META-INF/com/google/android
	install -c -m 0755 firstrun.sh $(DESTDIR)/META-INF/com/google/android/update-binary
	install -c -m 0755 mkfs.fat $(DESTDIR)
	$(STRIP) $(DESTDIR)/mkfs.fat
	install -c -m 0644 align.sh $(DESTDIR)

clean:
	rm -rf $(DESTDIR)
	rm -f mkfs.fat
	$(MAKE) -C $(DOSFSTOOLS_SRC) distclean

.PHONY: all install clean
