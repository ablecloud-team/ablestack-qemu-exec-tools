PREFIX=/usr
BINDIR=$(PREFIX)/bin
DOCDIR=$(PREFIX)/share/doc/ablestack-qemu-exec-tools

all:
	echo "No build step required."

install:
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 bin/vm_exec.sh $(DESTDIR)$(BINDIR)/vm_exec.sh
	install -d $(DESTDIR)$(DOCDIR)
	cp -r docs/* $(DESTDIR)$(DOCDIR)/

clean:
	rm -rf build/

rpm:
	tar -czf rpmbuild/SOURCES/ablestack-qemu-exec-tools-1.0.0.tar.gz *
	rpmbuild -ba rpmbuild/SPECS/ablestack-qemu-exec-tools.spec
