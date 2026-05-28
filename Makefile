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
N2K_NAME = ablestack_n2k
N2K_SPEC = rpm/$(N2K_NAME).spec
N2K_COMPLETIONS_FILE = completions/$(N2K_NAME)

HANGCTL_NAME = ablestack_vm_hangctl
HANGCTL_SPEC = rpm/$(HANGCTL_NAME).spec
FTCTL_NAME = ablestack_vm_ftctl
FTCTL_SPEC = rpm/$(FTCTL_NAME).spec

# Read VERSION file
VERSION := $(shell . ./VERSION; printf "%s" "$$VERSION" | tr -d '\r\n[:space:]')
RELEASE := $(shell . ./VERSION; printf "%s" "$$RELEASE" | tr -d '\r\n[:space:]')

# Extract git hash dynamically at execution time
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

.PHONY: all install uninstall rpm v2k-rpm n2k-rpm n2k-deb hangctl-rpm ftctl-rpm deb windows clean

all:
	@echo "Available targets: install, uninstall, rpm, deb, windows, clean"
	@echo "VERSION: $(VERSION), RELEASE: $(RELEASE), GIT_HASH: $(GIT_HASH)"

install:
	@echo "Installing $(NAME)..."
	install -d $(BIN_DIR)
	install -m 0755 bin/vm_exec.sh $(BIN_DIR)/vm_exec
	install -m 0755 bin/agent_policy_fix.sh $(BIN_DIR)/agent_policy_fix
	@if [ -f bin/ablestack_vm_ftctl.sh ]; then install -m 0755 bin/ablestack_vm_ftctl.sh $(BIN_DIR)/ablestack_vm_ftctl; fi
	@if [ -f bin/ablestack_n2k.sh ]; then install -m 0755 bin/ablestack_n2k.sh $(BIN_DIR)/ablestack_n2k; fi
	@if [ -f bin/ablestack_vm_ftctl_selftest.sh ]; then install -m 0755 bin/ablestack_vm_ftctl_selftest.sh $(BIN_DIR)/ablestack_vm_ftctl_selftest; fi
	@if [ -f bin/ablestack_vm_ftctl_firewalld.sh ]; then install -m 0755 bin/ablestack_vm_ftctl_firewalld.sh $(BIN_DIR)/ablestack_vm_ftctl_firewalld; fi
	@if [ -f install.sh ]; then install -m 0755 install.sh $(BIN_DIR)/install_ablestack_qemu_exec_tools; fi
	install -d $(LIB_TARGET)
	cp -a lib/* $(LIB_TARGET)/
	@if [ -f completions/ablestack_v2k ] || [ -f completions/ablestack_vm_ftctl ]; then \
		install -d $(COMPLETIONS_TARGET); \
	fi
	@if [ -f completions/ablestack_v2k ]; then \
		install -m 0644 completions/ablestack_v2k $(COMPLETIONS_TARGET)/ablestack_v2k; \
	fi
	@if [ -f completions/ablestack_vm_ftctl ]; then \
		install -m 0644 completions/ablestack_vm_ftctl $(COMPLETIONS_TARGET)/ablestack_vm_ftctl; \
	fi
	@if [ -f completions/ablestack_n2k ]; then \
		install -m 0644 completions/ablestack_n2k $(COMPLETIONS_TARGET)/ablestack_n2k; \
	fi
	@echo "Installed to $(INSTALL_PREFIX)"

##### ------------------------------------------------------------
##### ablestack-qemu-exec-tools: uninstall targets (via uninstall.sh)
##### ------------------------------------------------------------

# uninstall.sh path, relative to repository root
UNINSTALL_SCRIPT ?= ./uninstall.sh

# Map Make variables to uninstall.sh flags
# Example: make uninstall NO_PROMPT=1 PURGE=1 REMOVE_ISO=1
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

## Default uninstall target
uninstall:
	@echo ">> Running $(UNINSTALL_SCRIPT) $(UNINSTALL_FLAGS)"
	@sudo $(UNINSTALL_SCRIPT) $(UNINSTALL_FLAGS)

## Print uninstall plan only
uninstall-dry-run:
	@$(MAKE) uninstall DRY_RUN=1

## Remove everything including libraries, no backup
uninstall-purge:
	@$(MAKE) uninstall NO_PROMPT=1 PURGE=1

## Remove ISO files as well
uninstall-remove-iso:
	@$(MAKE) uninstall NO_PROMPT=1 REMOVE_ISO=1

## Keep selected components
uninstall-keep-bins:
	@$(MAKE) uninstall KEEP_BINS=1

uninstall-keep-profile:
	@$(MAKE) uninstall KEEP_PROFILE=1

uninstall-keep-lib:
	@$(MAKE) uninstall KEEP_LIB=1


rpm:
	@echo "Building RPM..."
	mkdir -p rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	@TMP_TGZ="$$(mktemp /tmp/ablestack-qemu-exec-tools-$(VERSION).tar.gz.XXXXXX)"; \
	tar czf "$$TMP_TGZ" \
		--transform="s,^,ablestack-qemu-exec-tools-$(VERSION)/," \
		--exclude=./rpmbuild \
		--exclude=./rpmbuild_v2k \
		--exclude=./rpmbuild_n2k \
		--exclude=./rpmbuild_hangctl \
		--exclude=./rpmbuild_ftctl \
		--exclude=./build \
		--exclude=./release \
		--exclude=./repo \
		--exclude=./dist \
		. ; \
	mv -f "$$TMP_TGZ" "rpmbuild/SOURCES/ablestack-qemu-exec-tools-$(VERSION).tar.gz"

	# Copy spec file from rpm directory
	cp rpm/$(NAME).spec rpmbuild/SPECS/

	rpmbuild --noplugins -ba --define "_topdir $(shell pwd)/rpmbuild" \
	         --define "version $(VERSION)" \
	         --define "release $(RELEASE)" \
	         --define "githash $(GIT_HASH)" \
	         rpmbuild/SPECS/$(NAME).spec

	# Collect build artifacts
	mkdir -p build/rpm
	cp rpmbuild/RPMS/noarch/*.rpm build/rpm/
	@echo "RPM package created: build/rpm/"

hangctl-rpm:
	@echo "Building HANGCTL RPM (isolated)..."
	@test -f "$(HANGCTL_SPEC)" || (echo "[ERR] Missing spec: $(HANGCTL_SPEC)" >&2; exit 2)

	@mkdir -p rpmbuild_hangctl/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

	@echo "[INFO] Packing sources to temp (avoid self-include)..."
	@TMP_TGZ="$$(mktemp /tmp/$(HANGCTL_NAME)-$(VERSION).tar.gz.XXXXXX)"; \
	tar czf "$$TMP_TGZ" \
		--transform="s,^,$(HANGCTL_NAME)-$(VERSION)/," \
		--exclude=./rpmbuild \
		--exclude=./rpmbuild_v2k \
		--exclude=./rpmbuild_n2k \
		--exclude=./rpmbuild_hangctl \
		--exclude=./rpmbuild_ftctl \
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
	@echo "HANGCTL RPM package created: build/rpm-hangctl/"

ftctl-rpm:
	@echo "Building FTCTL RPM (isolated)..."
	@test -f "$(FTCTL_SPEC)" || (echo "[ERR] Missing spec: $(FTCTL_SPEC)" >&2; exit 2)
	@test -f "completions/$(FTCTL_NAME)" || (echo "[ERR] Missing completion file: completions/$(FTCTL_NAME)" >&2; exit 2)

	@mkdir -p rpmbuild_ftctl/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	@TMP_TGZ="$$(mktemp /tmp/$(FTCTL_NAME)-$(VERSION).tar.gz.XXXXXX)"; \
	tar czf "$$TMP_TGZ" \
		--transform="s,^,$(FTCTL_NAME)-$(VERSION)/," \
		--exclude=./rpmbuild \
		--exclude=./rpmbuild_v2k \
		--exclude=./rpmbuild_n2k \
		--exclude=./rpmbuild_hangctl \
		--exclude=./rpmbuild_ftctl \
		--exclude=./build \
		--exclude=./release \
		--exclude=./repo \
		--exclude=./dist \
		. ; \
	mv -f "$$TMP_TGZ" "rpmbuild_ftctl/SOURCES/$(FTCTL_NAME)-$(VERSION).tar.gz"

	@cp $(FTCTL_SPEC) rpmbuild_ftctl/SPECS/

	rpmbuild --noplugins -ba --define "_topdir $(shell pwd)/rpmbuild_ftctl" \
	         --define "version $(VERSION)" \
	         --define "release $(RELEASE)" \
	         --define "githash $(GIT_HASH)" \
	         rpmbuild_ftctl/SPECS/$(FTCTL_NAME).spec

	mkdir -p build/rpm-ftctl
	cp rpmbuild_ftctl/RPMS/noarch/*.rpm build/rpm-ftctl/ 2>/dev/null || true
	cp rpmbuild_ftctl/RPMS/*/*.rpm build/rpm-ftctl/ 2>/dev/null || true
	@echo "FTCTL RPM package created: build/rpm-ftctl/"

v2k-rpm:
	@echo "Building V2K RPM (isolated)..."
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
		--exclude=./rpmbuild_n2k \
		--exclude=./rpmbuild_hangctl \
		--exclude=./rpmbuild_ftctl \
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

	@echo "Verifying completion file is included in ablestack_v2k RPM..."
	@RPM_FILE="$$(ls -1 build/rpm-v2k/$(V2K_NAME)-*.rpm 2>/dev/null | head -n 1)"; \
	if [ -z "$$RPM_FILE" ]; then \
	  echo "[ERR] Built RPM not found under build/rpm-v2k" >&2; exit 2; \
	fi; \
	rpm -qlp "$$RPM_FILE" | grep -qE "bash-completion/completions/$(V2K_NAME)$$" || \
	  (echo "[ERR] completion file missing in RPM: $$RPM_FILE" >&2; exit 2); \
	rpm -qlp "$$RPM_FILE" | grep -qE "/usr/share/ablestack/v2k/runtime-assets/assets/govc_Linux_x86_64.tar.gz$$" || \
	  (echo "[ERR] govc runtime asset missing in RPM: $$RPM_FILE" >&2; exit 2); \
	rpm -qlp "$$RPM_FILE" | grep -qE "/usr/share/ablestack/v2k/runtime-assets/assets/VMware-vix-disklib-.*[.]tar[.]gz$$" || \
	  (echo "[ERR] VDDK runtime asset missing in RPM: $$RPM_FILE" >&2; exit 2); \
	rpm -qlp "$$RPM_FILE" | grep -qE "/usr/share/ablestack/v2k/runtime-assets/assets/compat/vsphere80/govc_Linux_x86_64.tar.gz$$" || \
	  (echo "[ERR] profile govc runtime asset missing in RPM: $$RPM_FILE" >&2; exit 2); \
	rpm -qlp "$$RPM_FILE" | grep -qE "/usr/share/ablestack/v2k/compat/vsphere80/profile.json$$" || \
	  (echo "[ERR] compat profile missing in RPM: $$RPM_FILE" >&2; exit 2); \
	rpm -qlp "$$RPM_FILE" | grep -qE "/usr/share/ablestack/v2k/compat/esxi55/profile.json$$" || \
	  (echo "[ERR] esxi55 compat profile missing in RPM: $$RPM_FILE" >&2; exit 2); \
	rpm -qlp "$$RPM_FILE" | grep -qE "/usr/share/ablestack/v2k/runtime-assets/assets/compat/esxi55/VMware-vix-disklib-6[.]0[.]2-3566099[.]x86_64[.]tar[.]gz$$" || \
	  (echo "[ERR] esxi55 VDDK runtime asset missing in RPM: $$RPM_FILE" >&2; exit 2); \
	rpm -qlp "$$RPM_FILE" | grep -qE "/usr/share/ablestack/v2k/runtime-assets/assets/compat/esxi55/nbdkit-vddk-legacy-1[.]14[.]2-rocky9-x86_64[.]tar[.]gz$$" || \
	  (echo "[ERR] esxi55 legacy nbdkit runtime asset missing in RPM: $$RPM_FILE" >&2; exit 2); \
	rpm -qlp "$$RPM_FILE" | grep -qE "/usr/share/ablestack/v2k/runtime-assets/assets/compat/esxi55/wheels/pyvmomi-5[.]5[.]0[.]2014[.]1[.]1[.]tar[.]gz$$" || \
	  (echo "[ERR] esxi55 pyVmomi runtime asset missing in RPM: $$RPM_FILE" >&2; exit 2); \
	if find winpe -maxdepth 1 -type f -name '*.iso' 2>/dev/null | grep -q .; then \
	  rpm -qlp "$$RPM_FILE" | grep -qE "/usr/share/ablestack/v2k/winpe/.*[.]iso$$" || \
	    (echo "[ERR] staged WinPE ISO missing in RPM: $$RPM_FILE" >&2; exit 2); \
	fi

	@echo "V2K RPM package created: build/rpm-v2k/"

n2k-rpm:
	@echo "Building N2K RPM (isolated)..."
	@test -f "$(N2K_SPEC)" || (echo "[ERR] Missing spec: $(N2K_SPEC)" >&2; exit 2)
	@test -f "$(N2K_COMPLETIONS_FILE)" || (echo "[ERR] Missing completion file: $(N2K_COMPLETIONS_FILE)" >&2; exit 2)

	mkdir -p rpmbuild_n2k/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	@TMP_TGZ="$$(mktemp /tmp/$(N2K_NAME)-$(VERSION).tar.gz.XXXXXX)"; \
	tar czf "$$TMP_TGZ" \
		--transform="s,^,$(N2K_NAME)-$(VERSION)/," \
		--exclude=./rpmbuild \
		--exclude=./rpmbuild_v2k \
		--exclude=./rpmbuild_n2k \
		--exclude=./rpmbuild_hangctl \
		--exclude=./rpmbuild_ftctl \
		--exclude=./build \
		--exclude=./release \
		--exclude=./repo \
		--exclude=./dist \
		. ; \
	mv -f "$$TMP_TGZ" "rpmbuild_n2k/SOURCES/$(N2K_NAME)-$(VERSION).tar.gz"

	cp $(N2K_SPEC) rpmbuild_n2k/SPECS/

	rpmbuild --noplugins -ba --define "_topdir $(shell pwd)/rpmbuild_n2k" \
	         --define "version $(VERSION)" \
	         --define "release $(RELEASE)" \
	         --define "githash $(GIT_HASH)" \
	         rpmbuild_n2k/SPECS/$(N2K_NAME).spec

	mkdir -p build/rpm-n2k
	cp rpmbuild_n2k/RPMS/noarch/*.rpm build/rpm-n2k/ 2>/dev/null || true
	cp rpmbuild_n2k/RPMS/*/*.rpm build/rpm-n2k/ 2>/dev/null || true

	@echo "Verifying ablestack_n2k RPM file list..."
	@RPM_FILE="$$(ls -1 build/rpm-n2k/$(N2K_NAME)-*.rpm 2>/dev/null | head -n 1)"; \
	if [ -z "$$RPM_FILE" ]; then \
	  echo "[ERR] Built RPM not found under build/rpm-n2k" >&2; exit 2; \
	fi; \
	rpm -qlp "$$RPM_FILE" | grep -qE "/usr/local/bin/$(N2K_NAME)$$" || \
	  (echo "[ERR] command missing in RPM: $$RPM_FILE" >&2; exit 2); \
	rpm -qlp "$$RPM_FILE" | grep -qE "/usr/local/lib/ablestack-qemu-exec-tools/n2k/engine.sh$$" || \
	  (echo "[ERR] n2k engine library missing in RPM: $$RPM_FILE" >&2; exit 2); \
	rpm -qlp "$$RPM_FILE" | grep -qE "bash-completion/completions/$(N2K_NAME)$$" || \
	  (echo "[ERR] completion file missing in RPM: $$RPM_FILE" >&2; exit 2)

	@echo "N2K RPM package created: build/rpm-n2k/"

n2k-deb:
	@echo "Building N2K DEB (isolated)..."
	rm -rf $(N2K_NAME)_$(VERSION)-$(RELEASE)
	mkdir -p $(N2K_NAME)_$(VERSION)-$(RELEASE)/DEBIAN
	mkdir -p $(N2K_NAME)_$(VERSION)-$(RELEASE)/usr/local/bin
	mkdir -p $(N2K_NAME)_$(VERSION)-$(RELEASE)/usr/local/lib/ablestack-qemu-exec-tools/n2k
	mkdir -p $(N2K_NAME)_$(VERSION)-$(RELEASE)/usr/share/bash-completion/completions
	mkdir -p $(N2K_NAME)_$(VERSION)-$(RELEASE)/usr/share/doc/$(N2K_NAME)

	install -m 0755 bin/ablestack_n2k.sh $(N2K_NAME)_$(VERSION)-$(RELEASE)/usr/local/bin/ablestack_n2k
	cp -a lib/n2k/* $(N2K_NAME)_$(VERSION)-$(RELEASE)/usr/local/lib/ablestack-qemu-exec-tools/n2k/
	install -m 0644 completions/ablestack_n2k $(N2K_NAME)_$(VERSION)-$(RELEASE)/usr/share/bash-completion/completions/ablestack_n2k
	cp -a docs/n2k/* $(N2K_NAME)_$(VERSION)-$(RELEASE)/usr/share/doc/$(N2K_NAME)/
	sed -e "s/\$${VERSION}/$(VERSION)/" \
		-e "s/\$${RELEASE}/$(RELEASE)/" \
		deb/ablestack_n2k.control > $(N2K_NAME)_$(VERSION)-$(RELEASE)/DEBIAN/control
	find $(N2K_NAME)_$(VERSION)-$(RELEASE)/usr/local/lib/ablestack-qemu-exec-tools/n2k -type f -name "*.sh" -exec chmod 0755 {} \;
	dpkg-deb --build $(N2K_NAME)_$(VERSION)-$(RELEASE)
	mkdir -p build/deb-n2k
	mv $(N2K_NAME)_$(VERSION)-$(RELEASE).deb build/deb-n2k/$(N2K_NAME)_$(VERSION)-$(RELEASE).deb
	@echo "Verifying ablestack_n2k DEB file list..."
	@DEB_FILE="build/deb-n2k/$(N2K_NAME)_$(VERSION)-$(RELEASE).deb"; \
	dpkg-deb -c "$$DEB_FILE" | grep -qE "\./usr/local/bin/$(N2K_NAME)$$" || \
	  (echo "[ERR] command missing in DEB: $$DEB_FILE" >&2; exit 2); \
	dpkg-deb -c "$$DEB_FILE" | grep -qE "\./usr/local/lib/ablestack-qemu-exec-tools/n2k/engine.sh$$" || \
	  (echo "[ERR] n2k engine library missing in DEB: $$DEB_FILE" >&2; exit 2); \
	dpkg-deb -c "$$DEB_FILE" | grep -qE "\./usr/share/bash-completion/completions/$(N2K_NAME)$$" || \
	  (echo "[ERR] completion file missing in DEB: $$DEB_FILE" >&2; exit 2)
	@echo "N2K DEB package created: build/deb-n2k/"

deb:
	@echo "Building DEB..."
	rm -rf $(DEB_BUILD_DIR)
	mkdir -p $(DEB_DEBIAN_DIR) $(DEB_BIN_DIR) $(DEB_LIB_DIR) $(DEB_DOC_DIR)

	# bin
	install -m 0755 bin/vm_exec.sh $(DEB_BIN_DIR)/vm_exec
	install -m 0755 bin/agent_policy_fix.sh $(DEB_BIN_DIR)/agent_policy_fix
	install -m 0755 bin/cloud_init_auto.sh $(DEB_BIN_DIR)/cloud_init_auto
	@if [ -f install.sh ]; then install -m 0755 install.sh $(DEB_BIN_DIR)/install_ablestack_qemu_exec_tools; fi

	# lib
	cp -a lib/* $(DEB_LIB_DIR)/ 2>/dev/null || :

	# docs and examples
	cp -a README.md $(DEB_DOC_DIR)/
	@if [ -d docs ]; then cp -a docs/* $(DEB_DOC_DIR)/; fi
	@if [ -f usage_agent_policy_fix.md ]; then cp -a usage_agent_policy_fix.md $(DEB_DOC_DIR)/; fi
	@if [ -d examples ]; then cp -a examples/* $(DEB_DOC_DIR)/; fi

	# Replace template values in control file
	sed -e "s/\$${VERSION}/$(VERSION)/" \
		-e "s/\$${RELEASE}/$(RELEASE)/" \
		deb/control > $(DEB_DEBIAN_DIR)/control

	# Add postinst if present
	@if [ -f deb/postinst ]; then \
		cp deb/postinst $(DEB_DEBIAN_DIR)/postinst; \
		chmod 755 $(DEB_DEBIAN_DIR)/postinst; \
	fi

	chmod 755 $(DEB_BIN_DIR)/*

	dpkg-deb --build $(DEB_BUILD_DIR)
	mkdir -p build/deb
	mv $(DEB_BUILD_DIR).deb build/deb/$(DEB_PKG).deb
	@echo "DEB package created: build/deb/$(DEB_PKG).deb"

windows:
	@echo "Building Windows MSI..."
	powershell -ExecutionPolicy Bypass -File windows/msi/build-msi.ps1 \
		-Version $(VERSION) -Release $(RELEASE) -GitHash $(GIT_HASH)
	mkdir -p build/msi
	cp windows/msi/out/* build/msi/ || echo "[WARN] No MSI files copied"
	@echo "Windows MSI built under build/msi/"


clean:
	rm -rf rpmbuild
	rm -rf rpmbuild_v2k
	rm -rf rpmbuild_n2k
	rm -rf rpmbuild_hangctl
	rm -rf $(DEB_BUILD_DIR)
	rm -rf $(N2K_NAME)_$(VERSION)-$(RELEASE)
	rm -f *.deb
	rm -rf build/*
