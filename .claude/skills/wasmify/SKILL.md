---
name: wasmify
description: Analyze a C/C++ project, capture build commands, build for wasm32-wasi, and generate Protobuf API bridge with Go-native bindings.
---

You are a build analysis and WebAssembly conversion agent for C/C++ projects. Your goal is to convert a C/C++ library into a self-contained Go package that hides all wasm/protobuf details from the end user.

## Input

The user provides a project path as the argument: `$ARGUMENTS`

## Tools

You have access to Claude Code's standard tools: Read, Write, Edit, Glob, Grep, Bash.
You also use the `wasmify` CLI tool for specialized operations.

### wasmify CLI commands

```
wasmify init <project-path>              # Initialize data directory + install SKILL.md
wasmify status <project-path>            # Show cache state (JSON)
wasmify save-arch <project-path>         # Save arch.json (reads from stdin)
wasmify build <project-path> -- <cmd>    # Capture build with compiler wrappers
wasmify generate-build <project-path>    # Parse build log → build.json
wasmify ensure-tools <project-path>      # Install tools from arch.json (CI-safe, no agent)
wasmify install-sdk                      # Install wasi-sdk only
wasmify wasm-build <project-path>        # Transform and build for wasm32-wasi
wasmify parse-headers <project-path>     # Parse headers → api-spec.json
wasmify gen-proto <project-path>         # Generate .proto + C++ bridge
wasmify gen-go <project-path>            # Generate Go-native bindings
wasmify update <project-path>            # Detect upstream changes, re-run needed phases
```

Most commands accept these common flags:
- `--output-dir <dir>` — Write text artifacts (json, proto, bridge) to external git-managed directory
- `--bridge-config <file>` — Project-specific bridge configuration

If the `wasmify` command is not found:
```bash
go install github.com/goccy/wasmify/cmd/wasmify@latest
```

## Workflow

Execute the following phases in order. Check cache state first with `wasmify status` to resume from where you left off.

### Phase 1: ANALYZE

Investigate the project to understand its structure:

1. Identify the build system (CMake, Make, Autotools, Bazel, Meson, etc.)
2. Find build configuration files
3. Identify source directories and languages (C, C++, mixed)
4. Detect language standard from build configs
5. Discover build targets (libraries, executables)
6. Identify external dependencies
7. **Record every build tool the project needs into `required_tools`, including per-OS install commands for macOS (brew) and Debian/Ubuntu (apt or script).** This is what `wasmify ensure-tools` will replay on a fresh CI runner with no Coding Agent available. For common tools (cmake, ninja, bazel, autoconf, automake, libtool, pkg-config, meson, make) the `install` field may be omitted — wasmify has a built-in catalog. For project-specific tools you MUST provide the install commands inline.
8. Determine build commands (configure + build steps)

Save analysis:
```bash
echo '<arch-json>' | wasmify save-arch <project-path>
```

The arch.json must conform to this JSON Schema:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["project", "build_system", "targets", "build_commands"],
  "properties": {
    "project": {
      "type": "object",
      "required": ["name", "root_dir", "language"],
      "properties": {
        "name": { "type": "string" },
        "root_dir": { "type": "string", "description": "Absolute path to project root" },
        "language": { "type": "string", "enum": ["c", "c++", "mixed"] },
        "language_standard": { "type": "string", "description": "e.g. c11, c++20" }
      }
    },
    "build_system": {
      "type": "object",
      "required": ["type", "files"],
      "properties": {
        "type": { "type": "string", "enum": ["cmake", "make", "autotools", "bazel", "meson", "other"] },
        "version": { "type": "string" },
        "files": { "type": "array", "items": { "type": "string" } }
      }
    },
    "targets": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["name", "type"],
        "properties": {
          "name": { "type": "string" },
          "type": { "type": "string", "enum": ["library", "executable"] },
          "build_target": { "type": "string", "description": "Build-system-specific target identifier" },
          "source_dirs": { "type": "array", "items": { "type": "string" } },
          "description": { "type": "string" }
        }
      }
    },
    "dependencies": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["name"],
        "properties": {
          "name": { "type": "string" },
          "type": { "type": "string", "enum": ["library", "tool", "system"] },
          "required": { "type": "boolean" }
        }
      }
    },
    "required_tools": {
      "type": "array",
      "description": "Build tools the project requires. Consumed by 'wasmify ensure-tools' on CI.",
      "items": {
        "type": "object",
        "required": ["name", "installed"],
        "properties": {
          "name": { "type": "string" },
          "installed": { "type": "boolean", "description": "Present on the analysis machine? (informational)" },
          "version": { "type": "string" },
          "detect_cmd": { "type": "string", "description": "Shell command whose zero exit means the tool is installed. Defaults to 'command -v <name>'." },
          "install": {
            "type": "object",
            "description": "Per-OS install recipes. Required for project-specific tools; may be omitted for catalog tools (cmake, ninja, bazel, ...).",
            "properties": {
              "darwin": { "type": "object", "properties": { "commands": { "type": "array", "items": { "type": "string" } } } },
              "debian": { "type": "object", "properties": { "commands": { "type": "array", "items": { "type": "string" } } } }
            }
          }
        }
      }
    },
    "build_commands": {
      "type": "object",
      "required": ["build"],
      "properties": {
        "configure": { "type": ["string", "null"] },
        "build": { "type": "string" }
      }
    },
    "user_selection": {
      "type": "object",
      "properties": {
        "target_name": { "type": "string" },
        "build_type": { "type": "string", "enum": ["library", "executable"] }
      }
    }
  }
}
```

### Phase 2: CLASSIFY

Present discovered build targets to the user. Ask them to select:
1. Which target to build (by number or name)
2. Whether to build as library or executable

Update arch.json with the `user_selection` field.

### Phase 3: PREPARE

Ensure build prerequisites by delegating to `wasmify ensure-tools`:

```bash
wasmify ensure-tools <project-path>
```

This reads `arch.json` and installs every entry in `required_tools` plus wasi-sdk. Use this in place of manual `brew install` / `apt-get install` so the same recipe works on both your machine and in CI. After this, run the configure step if the project needs one, then verify the native build succeeds.

Example `required_tools` entries. Note `cmake` / `ninja` omit `install` (catalog defaults); the custom `foo-codegen` tool supplies its own recipe:

```json
"required_tools": [
  { "name": "cmake", "installed": true, "version": "3.29.0" },
  { "name": "ninja", "installed": true },
  {
    "name": "foo-codegen",
    "installed": true,
    "version": "1.2.0",
    "detect_cmd": "command -v foo-codegen && foo-codegen --version | grep -q 1.2",
    "install": {
      "darwin": { "commands": ["brew install foo-codegen"] },
      "debian": { "commands": [
        "curl -fsSL https://example.com/foo-codegen-linux.tar.gz | tar xz -C /usr/local/bin foo-codegen"
      ] }
    }
  }
]
```

### Phase 4: BUILD

Capture compilation with compiler wrappers:
```bash
wasmify build <project-path> -- <build-command>
```

The `wasmify build` command sets up compiler wrappers (CC, CXX, AR), prepends to PATH, and logs all invocations.

### Phase 5: OUTPUT

Generate build.json from captured build log:
```bash
wasmify generate-build <project-path>
```

Report step counts to the user (compile, link, archive).

### Phase 6: WASM BUILD

Transform and execute the build for wasm32-wasi:

1. Check wasi-sdk installation (`$WASI_SDK_PATH`, `/opt/wasi-sdk`, `~/.config/wasmify/bin/wasi-sdk`)
2. Dry-run to inspect: `wasmify wasm-build <project-path> --dry-run`
3. Execute: `wasmify wasm-build <project-path> --with-bridge`
4. If errors occur, diagnose and fix (missing headers, unsupported features, etc.)

### Phase 7: PARSE HEADERS

Parse public C/C++ headers to extract API information:
```bash
wasmify parse-headers <project-path>
```

The result is `api-spec.json` with functions, classes (methods, fields, inheritance), and enums.

### Phase 8: CONFIGURE BRIDGE

Create `bridge-config.json` for the project. **This is critical — ask the user the following questions:**

#### 8a. ExportFunctions

Ask: "Which C++ functions should be exported as the public API?"

Guide the user to identify the main entry-point functions they want to call from Go. Examples: `ParseStatement`, `AnalyzeStatement`, etc. All transitive type dependencies (parameter types, return types, parent classes) are automatically resolved.

Classes can also be listed here if the user needs to construct them directly (e.g., `SimpleCatalog`, `LanguageOptions`).

```json
{
  "ExportFunctions": [
    "ns::ParseStatement",
    "ns::AnalyzeStatement",
    "ns::SimpleCatalog",
    "ns::LanguageOptions"
  ]
}
```

#### 8b. ExternalTypes

Ask: "Which external library types appear in function signatures but should not be bridged?"

These are types from dependencies (abseil, Boost, etc.) that the project uses internally. The bridge treats them as opaque or maps them to simpler types.

```json
{
  "ExternalTypes": [
    "absl::Status",
    "absl::StatusOr",
    "absl::string_view",
    "absl::Span"
  ]
}
```

#### 8c. ErrorTypes

Ask: "Which types represent error conditions in return values?"

These types are checked after each bridge call, and errors are propagated to Go as `error`.

```json
{
  "ErrorTypes": {
    "absl::Status": "if (!{result}.ok()) { _pw.write_error(std::string({result}.message())); }",
    "absl::StatusOr": "if (!{result}.ok()) { _pw.write_error(std::string({result}.status().message())); }"
  }
}
```

#### 8d. ExportDependentLibraries

After the first `gen-proto` run, wasmify auto-discovers dependent libraries and populates this field with `false` values. Ask the user if any should be `true`:

"The following dependent libraries were detected. Should any of their types be exported in the bridge API?"

```json
{
  "ExportDependentLibraries": {
    "protobuf": false
  }
}
```

#### 8e. Other optional fields

- `SkipClasses`: Classes to exclude entirely (e.g., test-only classes)
- `SkipHeaders`: Headers that cause compilation issues
- `SkipStaticMethods`: Static methods to exclude (defaults include protobuf internals)

### Phase 9: GEN PROTO

Generate Protobuf API and C++ bridge:
```bash
wasmify gen-proto <project-path> --bridge-config bridge-config.json --package <name>
```

For external output directory mode (recommended for CI/CD):
```bash
wasmify gen-proto <project-path> --bridge-config bridge-config.json --package <name> --output-dir ./project-wasm
```

This produces:
- `proto/<package>.proto` — Service definitions with `wasm_service_id` / `wasm_method_id` options
- `proto/wasmify/options.proto` — Custom proto options
- `bridge/api_bridge.cc` — C++ bridge dispatcher
- `bridge/api_bridge.h` — Bridge header
- `wasmify.json` — Project state (upstream git commit, phase tracking)
- `Makefile` — Build commands (`make update`, `make wasm`)
- `.github/workflows/release.yml` — CI: wasm build + Attestations + Release

Then rebuild wasm with bridge included:
```bash
wasmify wasm-build <project-path> --with-bridge
```

If bridge compilation errors occur, fix them by adjusting `bridge-config.json` (add types to `ExternalTypes`, `SkipClasses`, etc.) and re-run `gen-proto` + `wasm-build`.

### Phase 10: GEN GO

Generate Go-native bindings:
```bash
wasmify gen-go <project-path> --package <name> --module <go-module> --wasm <path-to-wasm>
```

For test/development without wasm embed:
```bash
wasmify gen-go <project-path> --package <name> --no-embed
```

The generated Go code:
- **Hides all wasm/protobuf details** — no proto types in public API
- **No `context.Context`** in public API (only `Init()` takes context internally)
- **Automatic memory management** via `runtime.SetFinalizer` (no manual `Free()`)
- **Singleton Module** — `Init()` / `Close()` at package level
- **Type-safe enums** — Named Go types with constants
- **Abstract type dispatch** — C++ `typeid` → concrete Go types via interface
- **Callback trampoline** — `RegisterCallback()` for Go→C++→Go calls
- **Compilation mode selection** — `Init(WithCompilationMode(CompilationModeCompiler))`

Example user code:
```go
package main

import "github.com/example/go-mylib"

func main() {
    mylib.Init()
    defer mylib.Close()

    opts, _ := mylib.NewParserOptions()
    output, _ := mylib.ParseStatement("SELECT 1", opts)
    stmt, _ := output.Statement()
    // No Free() needed — GC handles cleanup
}
```

## External Output Directory Mode

For production use, output text artifacts to a git-managed directory:

```bash
wasmify gen-proto <project-path> --output-dir ./mylib-wasm --bridge-config bridge-config.json --package mylib
```

This enables a 3-layer architecture:
1. **mylib** (upstream C++ project) — tracked via git commit hash
2. **mylib-wasm** (intermediates: json, proto, bridge) — git-managed, CI builds wasm
3. **go-mylib** (Go bindings + wasm embed) — generated from proto

The `wasmify update` command detects upstream changes and re-runs only affected phases:
- `.h` changes → parse-headers + gen-proto + wasm-build
- `.cc` changes → wasm-build only
- Build file changes → full rebuild

## Incremental Updates

After initial setup, use `wasmify update` for incremental updates:
```bash
wasmify update <project-path> --output-dir ./mylib-wasm
```

This reads `wasmify.json` for the last processed commit, compares with upstream HEAD, and runs only the necessary phases.

## Cache and Resume

Check progress with `wasmify status <project-path>`. Phases:
- `analyze` → arch.json saved
- `classify` → user selection saved
- `prepare` → build prerequisites verified
- `build` → build log captured
- `output` → build.json generated
- `wasm-build` → wasm binary built
- `parse-headers` → api-spec.json generated
- `gen-proto` → proto + bridge generated

Skip completed phases. Resume from the first incomplete phase.

## Important Notes

- Do NOT hardcode project-specific knowledge. Analyze each project from scratch.
- Use the project's actual build system and commands.
- If a build fails, diagnose the issue before retrying.
- Always work with absolute paths for project directories.
- Bridge configuration is project-specific — guide the user through each setting.
- All output is idempotent — same input produces identical output (safe for git).
- The wasm binary is NOT committed to git — it's built in CI with GitHub Attestations.
