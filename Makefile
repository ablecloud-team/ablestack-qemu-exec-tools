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

# Read VERSION file
VERSION := $(shell . ./VERSION; printf "%s" "$$VERSION" | tr -d '\r\n[:space:]')
RELEASE := $(shell . ./VERSION; printf "%s" "$$RELEASE" | tr -d '\r\n[:space:]')

# Git hash는 실행 시점에서 자동으로 추출
GIT_HASH := $(shell git rev-parse --short HEAD 2>/dev/null || echo "nogit")

INSTALL_PREFIX = /usr/local
BIN_DIR = $(INSTALL_PREFIX)/bin
LIB_TARGET = $(INSTALL_PREFIX)/lib/$(NAME)

DEB_PKG = $(NAME)_$(VERSION)-$(RELEASE)
DEB_BUILD_DIR = $(DEB_PKG)
DEB_DOC_DIR = $(DEB_BUILD_DIR)/usr/share/doc/$(NAME)
DEB_BIN_DIR = $(DEB_BUILD_DIR)/usr/bin
DEB_LIB_DIR = $(DEB_BUILD_DIR)/usr/libexec/$(NAME)
DEB_DEBIAN_DIR = $(DEB_BUILD_DIR)/DEBIAN

.PHONY: all install uninstall rpm deb windows clean

all:
	@echo "Available targets: install, uninstall, rpm, deb, windows, clean"
	@echo "VERSION: $(VERSION), RELEASE: $(RELEASE), GIT_HASH: $(GIT_HASH)"

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
	tar czf rpmbuild/SOURCES/$(NAME)-$(VERSION).tar.gz \
  			 --transform="s,^,$(NAME)-$(VERSION)/," .

	cp $(NAME).spec rpmbuild/SPECS/

	rpmbuild -ba --define "_topdir $(shell pwd)/rpmbuild" \
			--define "version $(VERSION)" \
			--define "release $(RELEASE)" \
			--define "githash $(GIT_HASH)" \
			rpmbuild/SPECS/$(NAME).spec



	# 산출물 정리
	mkdir -p build/rpm
	cp rpmbuild/RPMS/noarch/*.rpm build/rpm/
	@echo "✅ RPM package created: build/rpm/"


deb:
	@echo "📦 Building DEB..."
	rm -rf $(DEB_BUILD_DIR)
	mkdir -p $(DEB_DEBIAN_DIR) $(DEB_BIN_DIR) $(DEB_LIB_DIR) $(DEB_DOC_DIR)

	# bin
	install -m 0755 bin/vm_exec.sh $(DEB_BIN_DIR)/vm_exec
	install -m 0755 bin/agent_policy_fix.sh $(DEB_BIN_DIR)/agent_policy_fix
	install -m 0755 bin/cloud_init_auto.sh $(DEB_BIN_DIR)/cloud_init_auto
	@if [ -f install.sh ]; then install -m 0755 install.sh $(DEB_BIN_DIR)/install_ablestack_qemu_exec_tools; fi

	# lib
	cp -a lib/* $(DEB_LIB_DIR)/ 2>/dev/null || :

	# docs & examples
	cp -a README.md $(DEB_DOC_DIR)/
	@if [ -d docs ]; then cp -a docs/* $(DEB_DOC_DIR)/; fi
	@if [ -f usage_agent_policy_fix.md ]; then cp -a usage_agent_policy_fix.md $(DEB_DOC_DIR)/; fi
	@if [ -d examples ]; then cp -a examples/* $(DEB_DOC_DIR)/; fi

	# control 파일 치환 (템플릿 -> 실제 버전 적용)
	sed -e "s/\$${VERSION}/$(VERSION)/" \
		-e "s/\$${RELEASE}/$(RELEASE)/" \
		deb/control > $(DEB_DEBIAN_DIR)/control

	# postinst 파일 추가
	@if [ -f deb/postinst ]; then \
		cp deb/postinst $(DEB_DEBIAN_DIR)/postinst; \
		chmod 755 $(DEB_DEBIAN_DIR)/postinst; \
	fi

	chmod 755 $(DEB_BIN_DIR)/*

	dpkg-deb --build $(DEB_BUILD_DIR)
	mkdir -p build/deb
	mv $(DEB_BUILD_DIR).deb build/deb/$(DEB_PKG).deb
	@echo "✅ DEB package created: build/deb/$(DEB_PKG).deb"

windows:
	@echo "📦 Building Windows MSI..."
	powershell -ExecutionPolicy Bypass -File windows/msi/build-msi.ps1 \
		-Version $(VERSION) -Release $(RELEASE) -GitHash $(GIT_HASH)
	@echo "✅ Windows MSI built under build/msi/"

clean:
	rm -rf rpmbuild
	rm -rf $(DEB_BUILD_DIR)
	rm -f *.deb
	rm -rf build/*