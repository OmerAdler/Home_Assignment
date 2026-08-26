NGINX_VERSION ?= 1.25.5
BUILDER_IMAGE := nginx-echo-builder:bookworm
IMAGE_TAG     := nginx-echo:1.25-bookworm
OUT_DIR       := $(CURDIR)/dist
DEB_FILE      := $(OUT_DIR)/nginx_$(NGINX_VERSION)-1echo1_amd64.deb

REFERENCE_IMAGE := nginx:1.25-bookworm
PYTHON          ?= python

.PHONY: deb image test clean

deb:
	mkdir -p $(OUT_DIR)
	docker build -t $(BUILDER_IMAGE) build
	docker run --rm -e NGINX_VERSION=$(NGINX_VERSION) \
		-v $(OUT_DIR):/build/out \
		$(BUILDER_IMAGE)
	@echo "Built: $(DEB_FILE)"

image: deb
	docker build -f Containerfile -t $(IMAGE_TAG) .
	@echo "Built: $(IMAGE_TAG)"

# Boots both images side by side and diffs their HTTP behavior. Exits non-zero
# on any mismatch. Needs both images present; `make image` builds the candidate.
test:
	REFERENCE_IMAGE=$(REFERENCE_IMAGE) CANDIDATE_IMAGE=$(IMAGE_TAG) \
		$(PYTHON) test/compat_test.py


clean:
	rm -rf $(OUT_DIR)
	-docker rmi $(BUILDER_IMAGE) $(IMAGE_TAG)
