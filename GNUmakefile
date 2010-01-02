# use GNU Make to run tests in parallel, and without depending on RubyGems
all::
RUBY = ruby
RAKE = rake
GIT_URL = git://git.bogomips.org/ruby_posix_mq.git

GIT-VERSION-FILE: .FORCE-GIT-VERSION-FILE
	@./GIT-VERSION-GEN
-include GIT-VERSION-FILE
-include local.mk
ifeq ($(DLEXT),) # "so" for Linux
  DLEXT := $(shell $(RUBY) -rrbconfig -e 'puts Config::CONFIG["DLEXT"]')
endif
ifeq ($(RUBY_VERSION),)
  RUBY_VERSION := $(shell $(RUBY) -e 'puts RUBY_VERSION')
endif

base_bins := posix-mq.rb
bins := $(addprefix bin/, $(base_bins))
man1_bins := $(addsuffix .1, $(base_bins))
man1_paths := $(addprefix man/man1/, $(man1_bins))

install: $(bins)
	$(prep_setup_rb)
	$(RM) -r .install-tmp
	mkdir .install-tmp
	cp -p bin/* .install-tmp
	$(RUBY) setup.rb all
	$(RM) $^
	mv .install-tmp/* bin/
	$(RM) -r .install-tmp
	$(prep_setup_rb)

setup_rb_files := .config InstalledFiles
prep_setup_rb := @-$(RM) $(setup_rb_files);$(MAKE) -C $(ext) clean

clean:
	-$(MAKE) -C ext/posix_mq clean
	$(RM) $(setup_rb_files) ext/posix_mq/Makefile

man:
	$(MAKE) -C Documentation install-man

pkg_extra := GIT-VERSION-FILE NEWS ChangeLog
manifest: $(pkg_extra) man
	$(RM) .manifest
	$(MAKE) .manifest

.manifest:
	(git ls-files && \
         for i in $@ $(pkg_extra) $(man1_paths); \
	 do echo $$i; done) | LC_ALL=C sort > $@+
	cmp $@+ $@ || mv $@+ $@
	$(RM) $@+

NEWS: GIT-VERSION-FILE
	$(RAKE) -s news_rdoc > $@+
	mv $@+ $@

SINCE =
ChangeLog: LOG_VERSION = \
  $(shell git rev-parse -q "$(GIT_VERSION)" >/dev/null 2>&1 && \
          echo $(GIT_VERSION) || git describe)
ifneq ($(SINCE),)
ChangeLog: log_range = v$(SINCE)..$(LOG_VERSION)
endif
ChangeLog: GIT-VERSION-FILE
	@echo "ChangeLog from $(GIT_URL) ($(log_range))" > $@+
	@echo >> $@+
	git log $(log_range) | sed -e 's/^/    /' >> $@+
	mv $@+ $@

news_atom := http://bogomips.org/ruby_posix_mq/NEWS.atom.xml
cgit_atom := http://git.bogomips.org/cgit/ruby_posix_mq.git/atom/?h=master
atom = <link rel="alternate" title="Atom feed" href="$(1)" \
             type="application/atom+xml"/>

# using rdoc 2.4.1+
doc: .document NEWS ChangeLog
	for i in $(man1_bins); do > $$i; done
	rdoc -Na -t "$(shell sed -ne '1s/^= //p' README)"
	install -m644 COPYING doc/COPYING
	install -m644 $(shell grep '^[A-Z]' .document)  doc/
	$(MAKE) -C Documentation install-html install-man
	install -m644 $(man1_paths) doc/
	cd doc && for i in $(base_bins); do \
	  html=$$(echo $$i | sed 's/\.rb/_rb/')_1.html; \
	  sed -e '/"documentation">/r man1/'$$i'.1.html' \
		< $$html > tmp && mv tmp $$html; done
	$(RUBY) -i -p -e \
	  '$$_.gsub!("</title>",%q{\&$(call atom,$(cgit_atom))})' \
	  doc/ChangeLog.html
	$(RUBY) -i -p -e \
	  '$$_.gsub!("</title>",%q{\&$(call atom,$(news_atom))})' \
	  doc/NEWS.html doc/README.html
	$(RAKE) -s news_atom > doc/NEWS.atom.xml
	cd doc && ln README.html tmp && mv tmp index.html
	$(RM) $(man1_bins)

ifneq ($(VERSION),)
rfproject := qrp
rfpackage := posix_mq
pkggem := pkg/$(rfpackage)-$(VERSION).gem
pkgtgz := pkg/$(rfpackage)-$(VERSION).tgz
release_notes := release_notes-$(VERSION)
release_changes := release_changes-$(VERSION)

release-notes: $(release_notes)
release-changes: $(release_changes)
$(release_changes):
	$(RAKE) -s release_changes > $@+
	$(VISUAL) $@+ && test -s $@+ && mv $@+ $@
$(release_notes):
	GIT_URL=$(GIT_URL) $(RAKE) -s release_notes > $@+
	$(VISUAL) $@+ && test -s $@+ && mv $@+ $@

# ensures we're actually on the tagged $(VERSION), only used for release
verify:
	test x"$(shell umask)" = x0022
	git rev-parse --verify refs/tags/v$(VERSION)^{}
	git diff-index --quiet HEAD^0
	test `git rev-parse --verify HEAD^0` = \
	     `git rev-parse --verify refs/tags/v$(VERSION)^{}`

fix-perms:
	-git ls-tree -r HEAD | awk '/^100644 / {print $$NF}' | xargs chmod 644
	-git ls-tree -r HEAD | awk '/^100755 / {print $$NF}' | xargs chmod 755

gem: $(pkggem)

install-gem: $(pkggem)
	gem install $(CURDIR)/$<

$(pkggem): manifest fix-perms
	gem build $(rfpackage).gemspec
	mkdir -p pkg
	mv $(@F) $@

$(pkgtgz): distdir = $(basename $@)
$(pkgtgz): HEAD = v$(VERSION)
$(pkgtgz): manifest fix-perms
	@test -n "$(distdir)"
	$(RM) -r $(distdir)
	mkdir -p $(distdir)
	tar c `cat .manifest` | (cd $(distdir) && tar x)
	cd pkg && tar c $(basename $(@F)) | gzip -9 > $(@F)+
	mv $@+ $@

package: $(pkgtgz) $(pkggem)

test-release: verify package $(release_notes) $(release_changes)
release: verify package $(release_notes) $(release_changes)
	# make tgz release on RubyForge
	rubyforge add_release -f -n $(release_notes) -a $(release_changes) \
	  $(rfproject) $(rfpackage) $(VERSION) $(pkgtgz)
	# push gem to Gemcutter
	gem push $(pkggem)
	# in case of gem downloads from RubyForge releases page
	-rubyforge add_file \
	  $(rfproject) $(rfpackage) $(VERSION) $(pkggem)
else
gem install-gem: GIT-VERSION-FILE
	$(MAKE) $@ VERSION=$(GIT_VERSION)
endif

ext := ext/posix_mq/posix_mq_ext.$(DLEXT)
ext/posix_mq/Makefile: ext/posix_mq/extconf.rb
	cd $(@D) && $(RUBY) extconf.rb
$(ext): $(wildcard $(addprefix ext/posix_mq/,*.c *.h)) ext/posix_mq/Makefile
	$(MAKE) -C $(@D)

all:: test

build: $(ext)
test: test-unit
test-unit: build
	$(RUBY) -I lib:ext/posix_mq test/test_posix_mq.rb

.PHONY: .FORCE-GIT-VERSION-FILE doc manifest man test
