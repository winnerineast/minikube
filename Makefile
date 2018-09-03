# Copyright 2016 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Bump these on release
VERSION_MAJOR ?= 0
VERSION_MINOR ?= 28
VERSION_BUILD ?= 2
VERSION ?= v$(VERSION_MAJOR).$(VERSION_MINOR).$(VERSION_BUILD)
DEB_VERSION ?= $(VERSION_MAJOR).$(VERSION_MINOR)-$(VERSION_BUILD)
INSTALL_SIZE ?= $(shell du out/minikube-windows-amd64.exe | cut -f1)
BUILDROOT_BRANCH ?= 2018.05
REGISTRY?=gcr.io/k8s-minikube

HYPERKIT_BUILD_IMAGE 	?= karalabe/xgo-1.10.x
BUILD_IMAGE 	?= k8s.gcr.io/kube-cross:v1.10.1-1
ISO_BUILD_IMAGE ?= $(REGISTRY)/buildroot-image

ISO_VERSION ?= v0.28.1
ISO_BUCKET ?= minikube/iso

MINIKUBE_VERSION ?= $(ISO_VERSION)
MINIKUBE_BUCKET ?= minikube/releases
MINIKUBE_UPLOAD_LOCATION := gs://${MINIKUBE_BUCKET}

KERNEL_VERSION ?= 4.16.14

GOOS ?= $(shell go env GOOS)
GOARCH ?= $(shell go env GOARCH)
GOPATH ?= $(shell go env GOPATH)
BUILD_DIR ?= ./out
$(shell mkdir -p $(BUILD_DIR))

ORG := k8s.io
REPOPATH ?= $(ORG)/minikube

# Use system python if it exists, otherwise use Docker.
PYTHON := $(shell command -v python || echo "docker run --rm -it -v $(shell pwd):/minikube -w /minikube python python")
BUILD_OS := $(shell uname -s)

STORAGE_PROVISIONER_TAG := v1.8.1

# Set the version information for the Kubernetes servers
MINIKUBE_LDFLAGS := -X k8s.io/minikube/pkg/version.version=$(VERSION) -X k8s.io/minikube/pkg/version.isoVersion=$(ISO_VERSION) -X k8s.io/minikube/pkg/version.isoPath=$(ISO_BUCKET)
PROVISIONER_LDFLAGS := "$(MINIKUBE_LDFLAGS) -s -w"

MAKEDEPEND := GOPATH=$(GOPATH) ./makedepend.sh

MINIKUBEFILES := ./cmd/minikube/
HYPERKIT_FILES := ./cmd/drivers/hyperkit
STORAGE_PROVISIONER_FILES := ./cmd/storage-provisioner
KVM_DRIVER_FILES := ./cmd/drivers/kvm/

MINIKUBE_TEST_FILES := ./...

MINIKUBE_BUILD_TAGS := container_image_ostree_stub containers_image_openpgp
MINIKUBE_INTEGRATION_BUILD_TAGS := integration $(MINIKUBE_BUILD_TAGS)
SOURCE_DIRS = cmd pkg test

# $(call DOCKER, image, command)
define DOCKER
	docker run --rm -e IN_DOCKER=1 --user $(shell id -u):$(shell id -g) -w /go/src/$(REPOPATH) -v $(GOPATH):/go --entrypoint /bin/bash $(1) -c '$(2)'
endef

ifeq ($(BUILD_IN_DOCKER),y)
	MINIKUBE_BUILD_IN_DOCKER=y
endif

# If we are already running in docker,
# prevent recursion by unsetting the BUILD_IN_DOCKER directives.
# The _BUILD_IN_DOCKER variables should not be modified after this conditional.
ifeq ($(IN_DOCKER),1)
	MINIKUBE_BUILD_IN_DOCKER=n
endif

ifeq ($(GOOS),windows)
	IS_EXE = ".exe"
endif
out/minikube$(IS_EXE): out/minikube-$(GOOS)-$(GOARCH)$(IS_EXE)
	cp $< $@

out/minikube-windows-amd64.exe: out/minikube-windows-amd64
	cp out/minikube-windows-amd64 out/minikube-windows-amd64.exe

out/minikube.d: pkg/minikube/assets/assets.go
	$(MAKEDEPEND) out/minikube-$(GOOS)-$(GOARCH) $(ORG) $(MINIKUBEFILES) $^ > $@

-include out/minikube.d
out/minikube-%-$(GOARCH): pkg/minikube/assets/assets.go
ifeq ($(MINIKUBE_BUILD_IN_DOCKER),y)
	$(call DOCKER,$(BUILD_IMAGE),/usr/bin/make $@)
else
ifneq ($(GOPATH)/src/$(REPOPATH),$(PWD))
	$(warning Warning: Building minikube outside the GOPATH, should be $(GOPATH)/src/$(REPOPATH) but is $(PWD))
endif
	GOOS=$* GOARCH=$(GOARCH) go build -tags "$(MINIKUBE_BUILD_TAGS)" -ldflags="$(MINIKUBE_LDFLAGS)" -a -o $@ k8s.io/minikube/cmd/minikube
endif

.PHONY: e2e-%-amd64
e2e-%-amd64: out/minikube-%-amd64
	GOOS=$* GOARCH=amd64 go test -c k8s.io/minikube/test/integration --tags="$(MINIKUBE_INTEGRATION_BUILD_TAGS)" -o out/$@

e2e-windows-amd64.exe: e2e-windows-amd64
	mv $(BUILD_DIR)/e2e-windows-amd64 $(BUILD_DIR)/e2e-windows-amd64.exe

minikube_iso: # old target kept for making tests happy
	echo $(ISO_VERSION) > deploy/iso/minikube-iso/board/coreos/minikube/rootfs-overlay/etc/VERSION
	if [ ! -d $(BUILD_DIR)/buildroot ]; then \
		mkdir -p $(BUILD_DIR); \
		git clone --branch=$(BUILDROOT_BRANCH) https://github.com/buildroot/buildroot $(BUILD_DIR)/buildroot; \
	fi;
	$(MAKE) BR2_EXTERNAL=../../deploy/iso/minikube-iso minikube_defconfig -C $(BUILD_DIR)/buildroot
	$(MAKE) -C $(BUILD_DIR)/buildroot
	mv $(BUILD_DIR)/buildroot/output/images/rootfs.iso9660 $(BUILD_DIR)/minikube.iso

# Change buildroot configuration for the minikube ISO
.PHONY: iso-menuconfig
iso-menuconfig:
	$(MAKE) -C $(BUILD_DIR)/buildroot menuconfig
	$(MAKE) -C $(BUILD_DIR)/buildroot savedefconfig

# Change the kernel configuration for the minikube ISO
.PHONY: linux-menuconfig
linux-menuconfig:
	$(MAKE) -C $(BUILD_DIR)/buildroot/output/build/linux-$(KERNEL_VERSION)/ menuconfig
	$(MAKE) -C $(BUILD_DIR)/buildroot/output/build/linux-$(KERNEL_VERSION)/ savedefconfig
	cp $(BUILD_DIR)/buildroot/output/build/linux-$(KERNEL_VERSION)/defconfig deploy/iso/minikube-iso/board/coreos/minikube/linux_defconfig

out/minikube.iso: $(shell find deploy/iso/minikube-iso -type f)
ifeq ($(IN_DOCKER),1)
	$(MAKE) minikube_iso
else
	docker run --rm --workdir /mnt --volume $(CURDIR):/mnt $(ISO_DOCKER_EXTRA_ARGS) \
		--user $(shell id -u):$(shell id -g) --env HOME=/tmp --env IN_DOCKER=1 \
		$(ISO_BUILD_IMAGE) /usr/bin/make out/minikube.iso
endif

iso_in_docker:
	docker run -it --rm --workdir /mnt --volume $(CURDIR):/mnt $(ISO_DOCKER_EXTRA_ARGS) \
		--user $(shell id -u):$(shell id -g) --env HOME=/tmp --env IN_DOCKER=1 \
		$(ISO_BUILD_IMAGE) /bin/bash

test-iso:
	go test -v $(REPOPATH)/test/integration --tags=iso --minikube-args="--iso-url=file://$(shell pwd)/out/buildroot/output/images/rootfs.iso9660"

.PHONY: test-pkg
test-pkg/%:
	go test -v -test.timeout=30m $(REPOPATH)/$* --tags="$(MINIKUBE_BUILD_TAGS)"

.PHONY: depend
depend: out/minikube.d out/test.d out/docker-machine-driver-hyperkit.d out/storage-provisioner.d out/docker-machine-driver-kvm2.d

.PHONY: all
all: cross drivers e2e-cross

.PHONY: drivers
drivers: out/docker-machine-driver-hyperkit out/docker-machine-driver-kvm2

.PHONY: integration
integration: out/minikube
	go test -v -test.timeout=30m $(REPOPATH)/test/integration --tags="$(MINIKUBE_INTEGRATION_BUILD_TAGS)" $(TEST_ARGS)

.PHONY: integration-none-driver
integration-none-driver: e2e-linux-amd64 out/minikube-linux-amd64
	sudo -E out/e2e-linux-amd64 -testdata-dir "test/integration/testdata" -minikube-start-args="--vm-driver=none" -test.v -test.timeout=30m -binary=out/minikube-linux-amd64 $(TEST_ARGS)

.PHONY: integration-versioned
integration-versioned: out/minikube
	go test -v -test.timeout=30m $(REPOPATH)/test/integration --tags="$(MINIKUBE_INTEGRATION_BUILD_TAGS) versioned" $(TEST_ARGS)

.PHONY: test
out/test.d: pkg/minikube/assets/assets.go
	$(MAKEDEPEND) -t test $(ORG) $(MINIKUBE_TEST_FILES) $^ > $@

-include out/test.d
test:
	GOPATH=$(GOPATH) ./test.sh

pkg/minikube/assets/assets.go: $(shell find deploy/addons -type f)
	which go-bindata || GOBIN=$(GOPATH)/bin go get github.com/jteeuwen/go-bindata/...
	PATH="$(PATH):$(GOPATH)/bin" go-bindata -nomemcopy -o pkg/minikube/assets/assets.go -pkg assets deploy/addons/...

.PHONY: cross
cross: out/minikube-linux-amd64 out/minikube-darwin-amd64 out/minikube-windows-amd64.exe

.PHONY: e2e-cross
e2e-cross: e2e-linux-amd64 e2e-darwin-amd64 e2e-windows-amd64.exe

.PHONY: checksum
checksum:
	for f in out/minikube-linux-amd64 out/minikube-darwin-amd64 out/minikube-windows-amd64.exe out/minikube.iso; do \
		if [ -f "$${f}" ]; then \
			openssl sha256 "$${f}" | awk '{print $$2}' > "$${f}.sha256" ; \
		fi ; \
	done

.PHONY: clean
clean:
	rm -rf $(BUILD_DIR)
	rm -f pkg/minikube/assets/assets.go

.PHONY: gendocs
gendocs: out/docs/minikube.md

.PHONY: fmt
fmt:
	@gofmt -l -s -w $(SOURCE_DIRS)

out/docs/minikube.md: $(shell find cmd) $(shell find pkg/minikube/constants) pkg/minikube/assets/assets.go
	cd $(GOPATH)/src/$(REPOPATH) && go run -ldflags="$(MINIKUBE_LDFLAGS)" hack/gen_help_text.go

out/minikube_$(DEB_VERSION).deb: out/minikube-linux-amd64
	cp -r installers/linux/deb/minikube_deb_template out/minikube_$(DEB_VERSION)
	chmod 0755 out/minikube_$(DEB_VERSION)/DEBIAN
	sed -E -i 's/--VERSION--/'$(DEB_VERSION)'/g' out/minikube_$(DEB_VERSION)/DEBIAN/control
	mkdir -p out/minikube_$(DEB_VERSION)/usr/bin
	cp out/minikube-linux-amd64 out/minikube_$(DEB_VERSION)/usr/bin/minikube
	dpkg-deb --build out/minikube_$(DEB_VERSION)
	rm -rf out/minikube_$(DEB_VERSION)

.SECONDEXPANSION:
TAR_TARGETS_linux   := out/minikube-linux-amd64 out/docker-machine-driver-kvm2
TAR_TARGETS_darwin  := out/minikube-darwin-amd64
TAR_TARGETS_windows := out/minikube-windows-amd64.exe
TAR_TARGETS_ALL     := $(shell find deploy/addons -type f)
out/minikube-%-amd64.tar.gz: $$(TAR_TARGETS_$$*) $(TAR_TARGETS_ALL)
	tar -cvf $@ $^

.PHONY: cross-tars
cross-tars: out/minikube-windows-amd64.tar.gz out/minikube-linux-amd64.tar.gz out/minikube-darwin-amd64.tar.gz

out/minikube-installer.exe: out/minikube-windows-amd64.exe
	rm -rf out/windows_tmp
	cp -r installers/windows/ out/windows_tmp
	cp -r LICENSE out/windows_tmp/LICENSE
	awk 'sub("$$", "\r")' out/windows_tmp/LICENSE > out/windows_tmp/LICENSE.txt
	sed -E -i 's/--VERSION_MAJOR--/'$(VERSION_MAJOR)'/g' out/windows_tmp/minikube.nsi
	sed -E -i 's/--VERSION_MINOR--/'$(VERSION_MINOR)'/g' out/windows_tmp/minikube.nsi
	sed -E -i 's/--VERSION_BUILD--/'$(VERSION_BUILD)'/g' out/windows_tmp/minikube.nsi
	sed -E -i 's/--INSTALL_SIZE--/'$(INSTALL_SIZE)'/g' out/windows_tmp/minikube.nsi
	cp out/minikube-windows-amd64.exe out/windows_tmp/minikube.exe
	makensis out/windows_tmp/minikube.nsi
	mv out/windows_tmp/minikube-installer.exe out/minikube-installer.exe
	rm -rf out/windows_tmp

out/docker-machine-driver-hyperkit.d:
	$(MAKEDEPEND) out/docker-machine-driver-hyperkit $(ORG) $(HYPERKIT_FILES) $^ > $@

-include out/docker-machine-driver-hyperkit.d
out/docker-machine-driver-hyperkit:
ifeq ($(MINIKUBE_BUILD_IN_DOCKER),y)
	$(call DOCKER,$(HYPERKIT_BUILD_IMAGE),CC=o64-clang CXX=o64-clang++ /usr/bin/make $@)
else
	GOOS=darwin CGO_ENABLED=1 go build -o $(BUILD_DIR)/docker-machine-driver-hyperkit k8s.io/minikube/cmd/drivers/hyperkit
endif

.PHONY: install-hyperkit-driver
install-hyperkit-driver: out/docker-machine-driver-hyperkit
	sudo cp out/docker-machine-driver-hyperkit $(HOME)/bin/docker-machine-driver-hyperkit
	sudo chown root:wheel $(HOME)/bin/docker-machine-driver-hyperkit
	sudo chmod u+s $(HOME)/bin/docker-machine-driver-hyperkit

.PHONY: check-release
check-release:
	go test -v ./deploy/minikube/release_sanity_test.go -tags=release

.PHONY: update-releases
update-releases:
	gsutil cp deploy/minikube/k8s_releases.json gs://minikube/k8s_releases.json

buildroot-image: $(ISO_BUILD_IMAGE) # convenient alias to build the docker container
$(ISO_BUILD_IMAGE): deploy/iso/minikube-iso/Dockerfile
	docker build $(ISO_DOCKER_EXTRA_ARGS) -t $@ -f $< $(dir $<)
	@echo ""
	@echo "$(@) successfully built"

out/storage-provisioner.d:
	$(MAKEDEPEND) out/storage-provisioner $(ORG) $(STORAGE_PROVISIONER_FILES) $^ > $@

-include out/storage-provisioner.d
out/storage-provisioner:
	GOOS=linux go build -o $(BUILD_DIR)/storage-provisioner -ldflags=$(PROVISIONER_LDFLAGS) cmd/storage-provisioner/main.go

.PHONY: storage-provisioner-image
storage-provisioner-image: out/storage-provisioner
	docker build -t $(REGISTRY)/storage-provisioner:$(STORAGE_PROVISIONER_TAG) -f deploy/storage-provisioner/Dockerfile .

.PHONY: push-storage-provisioner-image
push-storage-provisioner-image: storage-provisioner-image
	gcloud docker -- push $(REGISTRY)/storage-provisioner:$(STORAGE_PROVISIONER_TAG)

.PHONY: release-iso
release-iso: minikube_iso checksum
	gsutil cp out/minikube.iso gs://$(ISO_BUCKET)/minikube-$(ISO_VERSION).iso
	gsutil cp out/minikube.iso.sha256 gs://$(ISO_BUCKET)/minikube-$(ISO_VERSION).iso.sha256

.PHONY: release-minikube
release-minikube: out/minikube checksum
	gsutil cp out/minikube-$(GOOS)-$(GOARCH) $(MINIKUBE_UPLOAD_LOCATION)/$(MINIKUBE_VERSION)/minikube-$(GOOS)-$(GOARCH)
	gsutil cp out/minikube-$(GOOS)-$(GOARCH).sha256 $(MINIKUBE_UPLOAD_LOCATION)/$(MINIKUBE_VERSION)/minikube-$(GOOS)-$(GOARCH).sha256

out/docker-machine-driver-kvm2.d:
	$(MAKEDEPEND) out/docker-machine-driver-kvm2 $(ORG) $(KVM_DRIVER_FILES) $^ > $@

-include out/docker-machine-driver-kvm2.d
out/docker-machine-driver-kvm2:
	go build 																		\
		-installsuffix "static" 													\
		-ldflags "-X k8s.io/minikube/pkg/drivers/kvm/version.VERSION=$(VERSION)" 	\
		-tags libvirt.1.3.1 														\
		-o $(BUILD_DIR)/docker-machine-driver-kvm2 									\
		k8s.io/minikube/cmd/drivers/kvm
	chmod +X $@

.PHONY: install-kvm
install-kvm: out/docker-machine-driver-kvm2
	cp out/docker-machine-driver-kvm2 $(GOBIN)/docker-machine-driver-kvm2

.PHONY: release-kvm-driver
release-kvm-driver: install-kvm
	gsutil cp $(GOBIN)/docker-machine-driver-kvm2 gs://minikube/drivers/kvm/$(VERSION)/
