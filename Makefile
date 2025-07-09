# Makefile for ablestack-qemu-exec-tools
# Copyright 2025 ABLECLOUD
# Licensed under the Apache License 2.0

NAME = ablestack-qemu-exec-tools
VERSION = 0.1
INSTALL_PREFIX = /usr/local
BIN_TARGET = $(INSTALL_PREFIX)/bin/vm_exec
LIB_TARGET = $(INSTALL_PREFIX)/lib/$(NAME)

.PHONY: all install uninstall rpm clean

all:
	@echo "Available targets: install, uninstall, rpm, clean"

install:
	@echo "🔧 Installing $(NAME)..."
	install -d $(INSTALL_PREFIX)/bin
	install -m 0755 bin/vm_exec.sh $(BIN_TARGET)
	install -d $(LIB_TARGET)
	cp -a lib/* $(LIB_TARGET)/
	@echo "✅ Installed to $(INSTALL_PREFIX)"

uninstall:
	@echo "🗑 Uninstalling $(NAME)..."
	rm -f $(BIN_TARGET)
	rm -rf $(LIB_TARGET)
	@echo "✅ Uninstalled."

rpm:
	@echo "📦 Building RPM..."
	mkdir -p rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	tar czf rpmbuild/SOURCES/$(NAME)-$(VERSION).tar.gz --transform="s,^,$(NAME)-$(VERSION)/," .
	rpmbuild -ba --define "_topdir %(pwd)/rpmbuild" rpm/$(NAME).spec
	@echo "✅ RPM built under rpmbuild/RPMS/"

clean:
	rm -rf rpmbuild
