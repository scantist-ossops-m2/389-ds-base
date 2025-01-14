PWD ?= $(shell pwd)
RPMBUILD ?= $(PWD)/rpmbuild
RPM_VERSION ?= $(shell $(PWD)/rpm/rpmverrel.sh version)
RPM_RELEASE := $(shell $(PWD)/rpm/rpmverrel.sh release)
VERSION_PREREL := $(shell $(PWD)/rpm/rpmverrel.sh prerel)
RPM_VERSION_PREREL := $(subst .,-,$(VERSION_PREREL))
PACKAGE = 389-ds-base
RPM_NAME_VERSION = $(PACKAGE)-$(RPM_VERSION)$(RPM_VERSION_PREREL)
NAME_VERSION = $(PACKAGE)-$(RPM_VERSION)$(VERSION_PREREL)
TARBALL = $(NAME_VERSION).tar.bz2
JEMALLOC_URL ?= $(shell rpmspec -P $(RPMBUILD)/SPECS/389-ds-base.spec | awk '/^Source3:/ {print $$2}')
JEMALLOC_TARBALL ?= $(shell basename "$(JEMALLOC_URL)")
BUNDLE_JEMALLOC = 1
NODE_MODULES_TEST = src/cockpit/389-console/package-lock.json
NODE_MODULES_PATH = src/cockpit/389-console/
CARGO_PATH = src/
GIT_TAG = ${TAG}
# LIBDB tarball was generated from
#  https://kojipkgs.fedoraproject.org//packages/libdb/5.3.28/59.fc40/src/libdb-5.3.28-59.fc40.src.rpm
#  then uploaded in https://fedorapeople.org
LIBDB_URL ?= $(shell rpmspec -P $(RPMBUILD)/SPECS/389-ds-base.spec | awk '/^Source4:/ {print $$2}')
LIBDB_TARBALL ?= $(shell basename "$(LIBDB_URL)")
BUNDLE_LIBDB ?= 0

# Some sanitizers are supported only by clang
CLANG_ON = 0
# Address Sanitizer
ASAN_ON = 0
# Memory Sanitizer (clang only)
MSAN_ON = 0
# Thread Sanitizer
TSAN_ON = 0
# Undefined Behaviour Sanitizer
UBSAN_ON = 0

COCKPIT_ON = 1

clean:
	rm -rf dist
	rm -rf rpmbuild
	rm -rf vendor
	rm -f vendor.tar.gz

update-cargo-dependencies:
	cargo update --manifest-path=./src/Cargo.toml

download-cargo-dependencies:
	cargo update --manifest-path=./src/Cargo.toml
	cargo vendor --manifest-path=./src/Cargo.toml
	cargo fetch --manifest-path=./src/Cargo.toml
	tar -czf vendor.tar.gz vendor

bundle-rust-npm:
	python3 rpm/bundle-rust-npm.py $(CARGO_PATH) $(NODE_MODULES_PATH) $(DS_SPECFILE) --backup-specfile

install-node-modules:
ifeq ($(COCKPIT_ON), 1)
	cd src/cockpit/389-console; \
	rm -rf node_modules; \
	npm ci > /dev/null
ifndef SKIP_AUDIT_CI
	cd src/cockpit/389-console; \
	npx --yes audit-ci
endif
endif

build-cockpit: install-node-modules
ifeq ($(COCKPIT_ON), 1)
	cd src/cockpit/389-console; \
	rm -rf cockpit_dist; \
	NODE_ENV=production ./build.js; \
	cp -r dist cockpit_dist
endif

dist-bz2: install-node-modules download-cargo-dependencies
ifeq ($(COCKPIT_ON), 1)
	cd src/cockpit/389-console; \
	rm -rf cockpit_dist; \
	rm -rf dist; \
	NODE_ENV=production ./build.js; \
	cp -r dist cockpit_dist; \
	touch cockpit_dist/*; \
	touch -r package.json package-lock.json
endif
	tar cjf $(GIT_TAG).tar.bz2 --transform "s,^,$(GIT_TAG)/," $$(git ls-files) vendor/ src/cockpit/389-console/cockpit_dist/

local-archive: build-cockpit
	-mkdir -p dist/$(NAME_VERSION)
	rsync -a --exclude=node_modules --exclude=dist --exclude=__pycache__ --exclude=.git --exclude=rpmbuild . dist/$(NAME_VERSION)

tarballs: local-archive
	-mkdir -p dist/sources
	cd dist; tar cfj sources/$(TARBALL) $(NAME_VERSION)
ifeq ($(COCKPIT_ON), 1)
	cd src/cockpit/389-console; rm -rf dist
endif
	rm -rf dist/$(NAME_VERSION)
	cd dist/sources ; \
	if [ $(BUNDLE_JEMALLOC) -eq 1 ]; then \
		curl -LO $(JEMALLOC_URL) ; \
	fi ; \
	if [ $(BUNDLE_LIBDB) -eq 1 ]; then \
		curl -LO $(LIBDB_URL) ; \
	fi

rpmroot:
	rm -rf $(RPMBUILD)
	mkdir -p $(RPMBUILD)/BUILD
	mkdir -p $(RPMBUILD)/RPMS
	mkdir -p $(RPMBUILD)/SOURCES
	mkdir -p $(RPMBUILD)/SPECS
	mkdir -p $(RPMBUILD)/SRPMS
	sed -e s/__VERSION__/$(RPM_VERSION)/ -e s/__RELEASE__/$(RPM_RELEASE)/ \
	-e s/__VERSION_PREREL__/$(VERSION_PREREL)/ \
	-e s/__ASAN_ON__/$(ASAN_ON)/ \
	-e s/__MSAN_ON__/$(MSAN_ON)/ \
	-e s/__TSAN_ON__/$(TSAN_ON)/ \
	-e s/__UBSAN_ON__/$(UBSAN_ON)/ \
	-e s/__COCKPIT_ON__/$(COCKPIT_ON)/ \
	-e s/__CLANG_ON__/$(CLANG_ON)/ \
	-e s/__BUNDLE_JEMALLOC__/$(BUNDLE_JEMALLOC)/ \
	-e s/__BUNDLE_LIBDB__/$(BUNDLE_LIBDB)/ \
	rpm/$(PACKAGE).spec.in > $(RPMBUILD)/SPECS/$(PACKAGE).spec

rpmdistdir:
	mkdir -p dist/rpms

srpmdistdir:
	mkdir -p dist/srpms

rpmbuildprep:
	cp dist/sources/$(TARBALL) $(RPMBUILD)/SOURCES/
	cp rpm/$(PACKAGE)-* $(RPMBUILD)/SOURCES/
	if [ $(BUNDLE_JEMALLOC) -eq 1 ]; then \
		cp dist/sources/$(JEMALLOC_TARBALL) $(RPMBUILD)/SOURCES/ ; \
	fi
	if [ $(BUNDLE_LIBDB) -eq 1 ]; then \
		cp dist/sources/$(LIBDB_TARBALL) $(RPMBUILD)/SOURCES/ ; \
	fi

srpms: rpmroot srpmdistdir download-cargo-dependencies tarballs rpmbuildprep
	rpmbuild --define "_topdir $(RPMBUILD)" -bs $(RPMBUILD)/SPECS/$(PACKAGE).spec
	cp $(RPMBUILD)/SRPMS/$(RPM_NAME_VERSION)*.src.rpm dist/srpms/
	rm -rf $(RPMBUILD)

patch: rpmroot
	cp rpm/*.patch $(RPMBUILD)/SOURCES/
	rpm/add_patches.sh rpm $(RPMBUILD)/SPECS/$(PACKAGE).spec

patch_srpms: | patch srpms

rpms: rpmroot srpmdistdir rpmdistdir tarballs rpmbuildprep
	rpmbuild --define "_topdir $(RPMBUILD)" -ba $(RPMBUILD)/SPECS/$(PACKAGE).spec
	cp $(RPMBUILD)/RPMS/*/*$(RPM_VERSION)$(RPM_VERSION_PREREL)*.rpm dist/rpms/
	cp $(RPMBUILD)/SRPMS/$(RPM_NAME_VERSION)*.src.rpm dist/srpms/
	rm -rf $(RPMBUILD)

patch_rpms: | patch rpms
