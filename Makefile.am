opdir		  = $(datadir)/vyatta-op/templates
share_perl5dir	  = $(datarootdir)/perl5/Vyatta
tmplscriptdir = $(datadir)/tmplscripts

sbin_SCRIPTS  = scripts/vyatta-config-lldp.pl
bin_SCRIPTS   = scripts/vyatta-show-lldp.pl

cpiop = find  . ! -regex '\(.*~\|.*\.bak\|.*\.swp\|.*\#.*\#\)' -print0 | \
  cpio -0pd

install-exec-hook:
	mkdir -p $(DESTDIR)$(opdir)
	cd templates-op; $(cpiop) $(DESTDIR)$(opdir)
	mkdir -p $(DESTDIR)$(tmplscritdir)
	cd tmplscripts && $(cpiop) $(DESTDIR)$(tmplscriptdir)
