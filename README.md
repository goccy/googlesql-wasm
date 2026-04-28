# googlesql-wasm

[wasmify](https://github.com/goccy/wasmify) project that compiles
[googlesql](https://github.com/google/googlesql) to wasm32-wasip1 and
emits Go bindings on top.

## Outputs

The CI workflow at `.github/workflows/build.yml` and the local
`make wasm` target both produce two artefacts from a clean checkout:

| File | Where | What |
| --- | --- | --- |
| `googlesql.wasm` | `.wasmify/wasm-build/output/googlesql.wasm` | The wasi-sdk-built googlesql analyzer + sql_formatter, optimised by binaryen wasm-opt. |
| `googlesql.go` | repo root | `protoc-gen-wasmify-go`'s single-file Go bindings to the wasm. |

Both files are **regenerated** on every build; only the inputs below
are committed.

## Committed inputs

```
wasmify.json     # all wasmify decisions: project metadata, user_selection,
                 # bridge config, declarative skip rules
googlesql/       # git submodule pinned to the upstream commit we build against
buf.yaml         # buf module + wellknowntypes dep
buf.gen.yaml     # protoc-gen-wasmify-go invocation (out=., module=...)
```

Everything else (`build.json`, `api-spec.json`, `proto/`, `bridge/`,
`googlesql.wasm`, `googlesql.go`) is in `.gitignore` and reproduced by
`make wasm`.

## Building locally

The full pipeline runs inside a wasmify image that bundles wasi-sdk,
binaryen, bazelisk, buf, and the wasmify CLI. You don't install any
of those on your host — `make wasm` uses Docker to invoke them:

```sh
make wasm                 # uses ghcr.io/goccy/wasmify:edge
make wasm-clean           # drop regenerated outputs, keep committed inputs

# Iterate on an in-progress wasmify change locally:
make wasm IMAGE=localhost:5001/wasmify:local
```

`make wasm` runs (under `docker run --rm -v $PWD:/work …`) the same
six-step sequence as CI:

```
wasmify build --non-interactive    # bazel native build via compiler wrapper
wasmify generate-build             # build.log → build.json
wasmify parse-headers              # public C++ headers → api-spec.json
wasmify gen-proto                  # api-spec.json → proto/ + bridge/
wasmify wasm-build --optimize \
        --non-interactive          # build.json + bridge → googlesql.wasm + wasm-opt
buf generate                       # proto/ → googlesql.go
```

Resource defaults (`MEMORY=14g CPUS=8`) cover the googlesql peak
working set on an M-series Mac under colima or on a stock GitHub
ubuntu-latest runner. Override on smaller machines:

```sh
make wasm MEMORY=8g CPUS=4
```

## CI

`.github/workflows/build.yml` runs the same `make wasm`-equivalent
inside `ghcr.io/goccy/wasmify:edge` on `push` to `main`, `v*` tags,
and on manual `workflow_dispatch`. It uploads the two artefacts and
attaches an `actions/attest-build-provenance` SLSA attestation so
downstream consumers can `gh attestation verify` the binaries.
