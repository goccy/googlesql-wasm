# Container image that ships every toolchain wasmify needs (wasi-sdk +
# binaryen + bazelisk + buf + the wasmify CLI itself). Override locally
# to pin a specific SHA or to point at a private registry — e.g.
# `make wasm IMAGE=localhost:5001/wasmify:local` while iterating on a
# wasmify branch before publishing to ghcr.
IMAGE ?= ghcr.io/goccy/wasmify:v0.3.0

# Resource limits for the container that runs the wasm-build pipeline.
# googlesql's compile + link peak around ~6 GB RAM; bazel parallelism
# is bounded by CPUS.
MEMORY ?= 14g
CPUS   ?= 8

# Standard wasmify pipeline replayed inside the container, top-to-
# bottom. `wasmify build` captures the native bazel build via the
# compiler wrapper; subsequent phases consume its output. The final
# `--optimize` chains a binaryen wasm-opt pass after the link.
WASMIFY_PIPELINE = \
	wasmify build --non-interactive && \
	wasmify generate-build && \
	wasmify parse-headers && \
	wasmify gen-proto && \
	wasmify wasm-build --optimize --non-interactive && \
	buf generate

.PHONY: all wasm wasm-clean bundle-gomod image-pull help

# Module path stamped into the wasm2go bundle's go.mod. The bundle is
# released as a self-contained Go module, so it needs a go.mod that
# declares the import path the bundle's own `import "..."` and
# `//go:linkname` sites already embed. wasmify writes that path into
# wasmify.json's `bridge.Wasm2GoImportPath`, which the codegen reads
# back when it lays out the bundle — keep this in sync with that
# field by deriving it from the JSON at build time.
WASM2GO_BUNDLE_DIR     := build/wasm2go/internal/wasm2go
WASM2GO_MODULE_PATH    := $(shell jq -r '.bridge.Wasm2GoImportPath' wasmify.json 2>/dev/null)
# Match the go directive used by the bundle's downstream callers.
# Keeping it on a recent stable Go avoids forcing tag bumps every
# time the asm sidecars use a newer toolchain feature.
WASM2GO_BUNDLE_GO_VER  := 1.25.0

# Build googlesql.wasm + googlesql.go from a clean checkout, exactly
# the way the CI workflow at .github/workflows/build.yml does. Outputs:
#   .wasmify/wasm-build/output/googlesql.wasm
#   googlesql.go
#   build/wasm2go/                                <- wasm2go-runtime bridge
#   build/wasm2go/internal/wasm2go/go.mod         <- bundle module manifest
wasm:
	docker run --rm \
		-v $(CURDIR):/work -w /work \
		--memory=$(MEMORY) --cpus=$(CPUS) \
		$(IMAGE) \
		bash -c '$(WASMIFY_PIPELINE)'
	@$(MAKE) bundle-gomod

# Write go.mod into the wasm2go bundle so the released tarball is a
# self-contained Go module. Runs on the host (not inside the wasmify
# container) so it stays portable across image versions. The Go
# toolchain is not required — we just write a literal manifest.
bundle-gomod:
	@if [ ! -d "$(WASM2GO_BUNDLE_DIR)" ]; then \
		echo "$(WASM2GO_BUNDLE_DIR) does not exist — run 'make wasm' first" >&2; \
		exit 1; \
	fi
	@if [ -z "$(WASM2GO_MODULE_PATH)" ] || [ "$(WASM2GO_MODULE_PATH)" = "null" ]; then \
		echo "wasmify.json bridge.Wasm2GoImportPath is empty; cannot stamp bundle go.mod" >&2; \
		exit 1; \
	fi
	@printf 'module %s\n\ngo %s\n' "$(WASM2GO_MODULE_PATH)" "$(WASM2GO_BUNDLE_GO_VER)" \
		> $(WASM2GO_BUNDLE_DIR)/go.mod
	@echo "wrote $(WASM2GO_BUNDLE_DIR)/go.mod (module $(WASM2GO_MODULE_PATH))"

# Drop everything wasmify regenerates so the next `make wasm` runs
# from scratch. The committed inputs (wasmify.json, buf.{yaml,gen.yaml},
# the googlesql submodule) survive.
wasm-clean:
	rm -rf .wasmify api-spec.json build.json proto bridge googlesql.go \
	       build \
	       .wasmify/wasm-build/output/googlesql.wasm

# Refresh the cached toolchain image (runs `docker pull` so subsequent
# `make wasm` invocations pick up upstream wasmify changes).
image-pull:
	docker pull $(IMAGE)

all: wasm

help:
	@echo 'Targets:'
	@echo '  wasm         Build googlesql.wasm + googlesql.go inside $(IMAGE)'
	@echo '  wasm-clean   Drop generated artefacts; keep wasmify.json + submodule'
	@echo '  image-pull   docker pull $(IMAGE)'
	@echo ''
	@echo 'Variables:'
	@echo '  IMAGE   = $(IMAGE)'
	@echo '  MEMORY  = $(MEMORY)'
	@echo '  CPUS    = $(CPUS)'
