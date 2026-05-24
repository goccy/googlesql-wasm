# Container image that ships every toolchain wasmify needs (wasi-sdk +
# binaryen + bazelisk + buf + the wasmify CLI itself). Override locally
# to pin a specific SHA or to point at a private registry — e.g.
# `make wasm IMAGE=localhost:5001/wasmify:local` while iterating on a
# wasmify branch before publishing to ghcr.
IMAGE ?= ghcr.io/goccy/wasmify:edge

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

.PHONY: all wasm wasm-clean image-pull help

# Build googlesql.wasm + googlesql.go from a clean checkout, exactly
# the way the CI workflow at .github/workflows/build.yml does. Outputs:
#   .wasmify/wasm-build/output/googlesql.wasm
#   googlesql.go
wasm:
	docker run --rm \
		-v $(CURDIR):/work -w /work \
		--memory=$(MEMORY) --cpus=$(CPUS) \
		$(IMAGE) \
		bash -c '$(WASMIFY_PIPELINE)'

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
