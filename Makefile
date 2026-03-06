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
V2K_NAME = ablestack_v2k
V2K_SPEC = rpm/$(V2K_NAME).spec

HANGCTL_NAME = ablestack_vm_hangctl
HANGCTL_SPEC = rpm/$(HANGCTL_NAME).spec

# Read VERSION file
VERSION := $(shell . ./VERSION; printf "%s" "$$VERSION" | tr -d '\r\n[:space:]')
RELEASE := $(shell . ./VERSION; printf "%s" "$$RELEASE" | tr -d '\r\n[:space:]')

# Git hash???§Ìñâ ?úÏ†ê?êÏÑú ?êÎèô?ºÎ°ú Ï∂îÏ∂ú
GIT_HASH := $(shell git rev-parse --short HEAD 2>/dev/null || echo "nogit")

INSTALL_PREFIX = /usr/local
BIN_DIR = $(INSTALL_PREFIX)/bin
LIB_TARGET = $(INSTALL_PREFIX)/lib/$(NAME)
COMPLETIONS_SRC = completions
COMPLETIONS_TARGET = /usr/share/bash-completion/completions
COMPLETIONS_FILE = $(COMPLETIONS_SRC)/$(V2K_NAME)

DEB_PKG = $(NAME)_$(VERSION)-$(RELEASE)
DEB_BUILD_DIR = $(DEB_PKG)
DEB_DOC_DIR = $(DEB_BUILD_DIR)/usr/share/doc/$(NAME)
DEB_BIN_DIR = $(DEB_BUILD_DIR)/usr/bin
DEB_LIB_DIR = $(DEB_BUILD_DIR)/usr/libexec/$(NAME)
DEB_DEBIAN_DIR = $(DEB_BUILD_DIR)/DEBIAN
DEB_COMPLETIONS_DIR = $(DEB_BUILD_DIR)/usr/share/bash-completion/completions

.PHONY: all install uninstall rpm v2k-rpm hangctl-rpm deb windows clean

all:
	@echo "Available targets: install, uninstall, rpm, deb, windows, clean"
	@echo "VERSION: $(VERSION), RELEASE: $(RELEASE), GIT_HASH: $(GIT_HASH)"

install:
	@echo "?îß Installing $(NAME)..."
	install -d $(BIN_DIR)
	install -m 0755 bin/vm_exec.sh $(BIN_DIR)/vm_exec
	install -m 0755 bin/agent_policy_fix.sh $(BIN_DIR)/agent_policy_fix
	@if [ -f install.sh ]; then install -m 0755 install.sh $(BIN_DIR)/install_ablestack_qemu_exec_tools; fi
	install -d $(LIB_TARGET)
	cp -a lib/* $(LIB_TARGET)/
	@echo "??Installed to $(INSTALL_PREFIX)"

##### ?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä
##### ablestack-qemu-exec-tools: uninstall targets (via uninstall.sh)
##### ?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä

# uninstall.sh ?ÑÏπò (Î¶¨Ìè¨ÏßÄ?†Î¶¨ Î£®Ìä∏ Í∏∞Ï?)
UNINSTALL_SCRIPT ?= ./uninstall.sh

# ?åÎûòÍ∑∏Î? Make Î≥Ä?òÎ°ú ?úÏñ¥?????àÍ≤å Îß§Ìïë
# ?? make uninstall NO_PROMPT=1 PURGE=1 REMOVE_ISO=1
UNINSTALL_FLAGS :=
ifeq ($(strip $(DRY_RUN)),1)
  UNINSTALL_FLAGS += --dry-run
endif
ifeq ($(strip $(NO_PROMPT)),1)
  UNINSTALL_FLAGS += --no-prompt
endif
ifeq ($(strip $(PURGE)),1)
  UNINSTALL_FLAGS += --purge
endif
ifeq ($(strip $(REMOVE_ISO)),1)
  UNINSTALL_FLAGS += --remove-iso
endif
ifeq ($(strip $(KEEP_BINS)),1)
  UNINSTALL_FLAGS += --keep-bins
endif
ifeq ($(strip $(KEEP_PROFILE)),1)
  UNINSTALL_FLAGS += --keep-profile
endif
ifeq ($(strip $(KEEP_LIB)),1)
  UNINSTALL_FLAGS += --keep-lib
endif

.PHONY: uninstall uninstall-dry-run uninstall-purge uninstall-remove-iso \
        uninstall-keep-bins uninstall-keep-profile uninstall-keep-lib

## Í∏∞Î≥∏ ?úÍ±∞(Î¨¥ÌîÑÎ°¨ÌîÑ??Í∂åÏû•)
uninstall:
	@echo ">> Running $(UNINSTALL_SCRIPT) $(UNINSTALL_FLAGS)"
	@sudo $(UNINSTALL_SCRIPT) $(UNINSTALL_FLAGS)

## ?úÍ±∞ Í≥ÑÌöçÎß?Ï∂úÎ†•
uninstall-dry-run:
	@$(MAKE) uninstall DRY_RUN=1

## ?ºÏù¥Î∏åÎü¨Î¶¨ÍπåÏßÄ ?ÑÏ†Ñ ??†ú(Î∞±ÏóÖ ?ÜÏùå), Î¨¥ÌîÑÎ°¨ÌîÑ??
uninstall-purge:
	@$(MAKE) uninstall NO_PROMPT=1 PURGE=1

## ISO ?åÏùºÍπåÏ? ??†ú(Î¨¥ÌîÑÎ°¨ÌîÑ??
uninstall-remove-iso:
	@$(MAKE) uninstall NO_PROMPT=1 REMOVE_ISO=1

## ?†ÌÉù ?†Ï? ?µÏÖò???ÅÌô©Î≥?Ï°∞Ìï© Í∞Ä??
uninstall-keep-bins:
	@$(MAKE) uninstall KEEP_BINS=1

uninstall-keep-profile:
	@$(MAKE) uninstall KEEP_PROFILE=1

uninstall-keep-lib:
	@$(MAKE) uninstall KEEP_LIB=1


rpm:
	@echo "?ì¶ Building RPM..."
	mkdir -p rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	@TMP_TGZ="$$(mktemp /tmp/ablestack-qemu-exec-tools-$(VERSION).tar.gz.XXXXXX)"; \
	tar czf "$$TMP_TGZ" \
		--transform="s,^,ablestack-qemu-exec-tools-$(VERSION)/," \
		--exclude=./rpmbuild \
		--exclude=./rpmbuild_v2k \
		--exclude=./rpmbuild_hangctl \
		--exclude=./build \
		--exclude=./release \
		--exclude=./repo \
		--exclude=./dist \
		. ; \
	mv -f "$$TMP_TGZ" "rpmbuild/SOURCES/ablestack-qemu-exec-tools-$(VERSION).tar.gz"

	# spec ?åÏùº Î≥µÏÇ¨ (rpm ?îÎ†â?†Î¶¨?êÏÑú Í∞Ä?∏Ïò§Í∏?
	cp rpm/$(NAME).spec rpmbuild/SPECS/

	rpmbuild --noplugins -ba --define "_topdir $(shell pwd)/rpmbuild" \
	         --define "version $(VERSION)" \
	         --define "release $(RELEASE)" \
	         --define "githash $(GIT_HASH)" \
	         rpmbuild/SPECS/$(NAME).spec

	# ?∞Ï∂úÎ¨??ïÎ¶¨
	mkdir -p build/rpm
	cp rpmbuild/RPMS/noarch/*.rpm build/rpm/
	@echo "??RPM package created: build/rpm/"

hangctl-rpm:
	@echo "?ì¶ Building HANGCTL RPM (isolated)..."
	@test -f "$(HANGCTL_SPEC)" || (echo "[ERR] Missing spec: $(HANGCTL_SPEC)" >&2; exit 2)

	@mkdir -p rpmbuild_hangctl/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

	@echo "[INFO] Packing sources to temp (avoid self-include)..."
	@TMP_TGZ="$$(mktemp /tmp/$(HANGCTL_NAME)-$(VERSION).tar.gz.XXXXXX)"; \
	tar czf "$$TMP_TGZ" \
		--transform="s,^,$(HANGCTL_NAME)-$(VERSION)/," \
		--exclude=./rpmbuild \
		--exclude=./rpmbuild_v2k \
		--exclude=./rpmbuild_hangctl \
		--exclude=./build \
		--exclude=./release \
		--exclude=./repo \
		--exclude=./dist \
		. ; \
	mv -f "$$TMP_TGZ" "rpmbuild_hangctl/SOURCES/$(HANGCTL_NAME)-$(VERSION).tar.gz"

	@cp $(HANGCTL_SPEC) rpmbuild_hangctl/SPECS/

	rpmbuild --noplugins -ba --define "_topdir $(shell pwd)/rpmbuild_hangctl" \
	         --define "version $(VERSION)" \
	         --define "release $(RELEASE)" \
	         --define "githash $(GIT_HASH)" \
	         rpmbuild_hangctl/SPECS/$(HANGCTL_NAME).spec

	mkdir -p build/rpm-hangctl
	cp rpmbuild_hangctl/RPMS/noarch/*.rpm build/rpm-hangctl/ 2>/dev/null || true
	cp rpmbuild_hangctl/RPMS/*/*.rpm build/rpm-hangctl/ 2>/dev/null || true
	@echo "??HANGCTL RPM package created: build/rpm-hangctl/"

v2k-rpm:
	@echo "?ì¶ Building V2K RPM (isolated)..."
	@test -f "$(V2K_SPEC)" || (echo "[ERR] Missing spec: $(V2K_SPEC)" >&2; exit 2)
	@test -f "$(COMPLETIONS_FILE)" || (echo "[ERR] Missing completion file: $(COMPLETIONS_FILE)" >&2; exit 2)

	@# Sanity check for new assets (does not fail build; spec may still package lib/v2k/*)
	@if [ -f "lib/v2k/fleet.sh" ]; then \
		echo "OK: lib/v2k/fleet.sh detected"; \
	else \
		echo "[WARN] Missing: lib/v2k/fleet.sh"; \
	fi
	echo "OK: $(COMPLETIONS_FILE) detected"

	# Fully isolated rpmbuild tree for V2K (keeps existing 'rpmbuild/' untouched)
	mkdir -p rpmbuild_v2k/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	@TMP_TGZ="$$(mktemp /tmp/ablestack_v2k-$(VERSION).tar.gz.XXXXXX)"; \
	tar czf "$$TMP_TGZ" \
		--transform="s,^,ablestack_v2k-$(VERSION)/," \
		--exclude=./rpmbuild \
		--exclude=./rpmbuild_v2k \
		--exclude=./rpmbuild_hangctl \
		--exclude=./build \
		--exclude=./release \
		--exclude=./repo \
		--exclude=./dist \
		. ; \
	mv -f "$$TMP_TGZ" "rpmbuild_v2k/SOURCES/ablestack_v2k-$(VERSION).tar.gz"

	cp $(V2K_SPEC) rpmbuild_v2k/SPECS/

	rpmbuild --noplugins -ba --define "_topdir $(shell pwd)/rpmbuild_v2k" \
	         --define "version $(VERSION)" \
	         --define "release $(RELEASE)" \
	         --define "githash $(GIT_HASH)" \
	         rpmbuild_v2k/SPECS/$(V2K_NAME).spec

	mkdir -p build/rpm-v2k
	cp rpmbuild_v2k/RPMS/noarch/*.rpm build/rpm-v2k/ 2>/dev/null || true
	cp rpmbuild_v2k/RPMS/*/*.rpm build/rpm-v2k/ 2>/dev/null || true

	@echo "?îé Verifying completion file is included in ablestack_v2k RPM..."
	@RPM_FILE="$$(ls -1 build/rpm-v2k/$(V2K_NAME)-*.rpm 2>/dev/null | head -n 1)"; \
	if [ -z "$$RPM_FILE" ]; then \
	  echo "[ERR] Built RPM not found under build/rpm-v2k" >&2; exit 2; \
	fi; \
	rpm -qlp "$$RPM_FILE" | grep -qE "bash-completion/completions/$(V2K_NAME)$$" || \
	  (echo "[ERR] completion file missing in RPM: $$RPM_FILE" >&2; exit 2)

	@echo "??V2K RPM package created: build/rpm-v2k/"

deb:
	@echo "?ì¶ Building DEB..."
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

	# control ?åÏùº ÏπòÌôò (?úÌîåÎ¶?-> ?§Ï†ú Î≤ÑÏ†Ñ ?ÅÏö©)
	sed -e "s/\$${VERSION}/$(VERSION)/" \
		-e "s/\$${RELEASE}/$(RELEASE)/" \
		deb/control > $(DEB_DEBIAN_DIR)/control

	# postinst ?åÏùº Ï∂îÍ?
	@if [ -f deb/postinst ]; then \
		cp deb/postinst $(DEB_DEBIAN_DIR)/postinst; \
		chmod 755 $(DEB_DEBIAN_DIR)/postinst; \
	fi

	chmod 755 $(DEB_BIN_DIR)/*

	dpkg-deb --build $(DEB_BUILD_DIR)
	mkdir -p build/deb
	mv $(DEB_BUILD_DIR).deb build/deb/$(DEB_PKG).deb
	@echo "??DEB package created: build/deb/$(DEB_PKG).deb"

windows:
	@echo "?ì¶ Building Windows MSI..."
	powershell -ExecutionPolicy Bypass -File windows/msi/build-msi.ps1 \
		-Version $(VERSION) -Release $(RELEASE) -GitHash $(GIT_HASH)
	mkdir -p build/msi
	cp windows/msi/out/* build/msi/ || echo "[WARN] No MSI files copied"
	@echo "??Windows MSI built under build/msi/"


clean:
	rm -rf rpmbuild
	rm -rf rpmbuild_v2k
	rm -rf rpmbuild_hangctl
	rm -rf $(DEB_BUILD_DIR)
	rm -f *.deb
	rm -rf build/*
