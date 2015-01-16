all::
PLACEHOLDERS = posix-mq-rb_1
RSYNC_DEST := bogomips.org:/srv/bogomips/ruby_posix_mq
rfpackage := posix_mq

base_bins := posix-mq-rb
bins := $(addprefix bin/, $(base_bins))
man1_rdoc := $(addsuffix _1, $(base_bins))
man1_bins := $(addsuffix .1, $(base_bins))
man1_paths := $(addprefix man/man1/, $(man1_bins))

clean:
	-$(MAKE) -C Documentation clean

man html:
	$(MAKE) -C Documentation install-$@

pkg_extra += $(man1_paths)
$(man1_paths): man
include pkg.mk

doc::
	install -m644 COPYING-GPL2 doc/COPYING-GPL2
.PHONY: man html
