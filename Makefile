# Makefile for ablestack-qemu-exec-tools
#
# Copyright 2025 ABLECLOUD
#
# Licensed under the Apache License, Version 2.0 (the "License");
# You may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

NAME = ablestack-qemu-exec-tools
VERSION = 0.1
RELEASE = 1
INSTALL_PREFIX = /usr/local
BIN_DIR = $(INSTALL_PREFIX)/bin
LIB_TARGET = $(INSTALL_PREFIX)/lib/$(NAME)

DEB_PKG = $(NAME)_$(VERSION)-$(RELEASE)
DEB_BUILD_DIR = $(DEB_PKG)
DEB_DOC_DIR = $(DEB_BUILD_DIR)/usr/share/doc/$(NAME)
DEB_BIN_DIR = $(DEB_BUILD_DIR)/usr/local/bin
DEB_LIB_DIR = $(DEB_BUILD_DIR)/usr/local/lib/$(NAME)
DEB_DEBIAN_DIR = $(DEB_BUILD_DIR)/DEBIAN

.PHONY: all install uninstall rpm deb clean

all:
	@echo "Available targets: install, uninstall, rpm, deb, clean"

install:
	@echo "🔧 Installing $(NAME)..."
	install -d $(BIN_DIR)
	install -m 0755 bin/vm_exec.sh $(BIN_DIR)/vm_exec
	install -m 0755 bin/agent_policy_fix.sh $(BIN_DIR)/agent_policy_fix
	@if [ -f install.sh ]; then install -m 0755 install.sh $(BIN_DIR)/install_ablestack_qemu_exec_tools; fi
	install -d $(LIB_TARGET)
	cp -a lib/* $(LIB_TARGET)/
	@echo "✅ Installed to $(INSTALL_PREFIX)"

uninstall:
	@echo "🗑 Uninstalling $(NAME)..."
	rm -f $(BIN_DIR)/vm_exec
	rm -f $(BIN_DIR)/agent_policy_fix
	rm -f $(BIN_DIR)/install_ablestack_qemu_exec_tools
	rm -rf $(LIB_TARGET)
	@echo "✅ Uninstalled."

rpm:
	@echo "📦 Building RPM..."
	mkdir -p rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	tar czf rpmbuild/SOURCES/$(NAME)-$(VERSION).tar.gz --transform="s,^,$(NAME)-$(VERSION)/," .
	rpmbuild -ba --define "_topdir $(shell pwd)/rpmbuild" rpm/$(NAME).spec
	@echo "✅ RPM built under rpmbuild/RPMS/"

deb:
	@echo "📦 Building DEB..."
	rm -rf $(DEB_BUILD_DIR)
	mkdir -p $(DEB_DEBIAN_DIR)
	mkdir -p $(DEB_BIN_DIR)
	mkdir -p $(DEB_LIB_DIR)
	mkdir -p $(DEB_DOC_DIR)
	# bin
	install -m 0755 bin/vm_exec.sh $(DEB_BIN_DIR)/vm_exec
	install -m 0755 bin/agent_policy_fix.sh $(DEB_BIN_DIR)/agent_policy_fix
	@if [ -f install.sh ]; then install -m 0755 install.sh $(DEB_BIN_DIR)/install_ablestack_qemu_exec_tools; fi
	# lib
	cp -a lib/* $(DEB_LIB_DIR)/
	# 문서 및 예제
	cp -a README.md $(DEB_DOC_DIR)/
	@if [ -d docs ]; then cp -a docs/* $(DEB_DOC_DIR)/; fi
	@if [ -f usage_agent_policy_fix.md ]; then cp -a usage_agent_policy_fix.md $(DEB_DOC_DIR)/; fi
	@if [ -d examples ]; then cp -a examples/* $(DEB_DOC_DIR)/; fi
	# control 파일 필요(최상위에 있어야 함)
	cp deb/control $(DEB_DEBIAN_DIR)/
	chmod 755 $(DEB_BIN_DIR)/*
	dpkg-deb --build $(DEB_BUILD_DIR)
	@echo "✅ DEB package created: $(DEB_PKG).deb"

clean:
	rm -rf rpmbuild
	rm -rf $(DEB_BUILD_DIR)
	rm -f *.deb
