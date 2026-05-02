# [CLAUDE.md](http://CLAUDE.md) — paramlib project guide

## What this project is

**paramlib** is a Zig library for parsing, storing, and querying DayZ/Arma "param" (`.cpp` / `.rvmat`) config files — the hierarchical class/parameter format used by Bohemia Interactive games. It ships three related deliverables built from a single `build.zig`:

OutputPathPurpose`paramlib` (exe)`zig-out/bin/paramlib`Thin driver (currently just a stub)`paramlib-lsp` (native exe)`zig-out/bin/paramlib-lsp`LSP server, reads stdio`paramlib-lsp.wasmzig-out/wasm/paramlib-lsp.wasm`Same LSP, WASM build for VS Code web`benchmark` (exe)`zig-out/bin/benchmark`Standalone microbenchmark, links libc`paramkit-*.vsixzig-out/vscode/`VS Code extension (opt-in, `-Dvscode=true`)

The Zig minimum version is **0.16.0-dev.2736** (nightly). The only external Zig dependency is `lsp_kit` (pinned via `build.zig.zon`).

---

## Repository layout

```
paramlib/
├── build.zig          Build script — defines all targets and steps
├── build.zig.zon      Package manifest (name, version, lsp_kit dep)
├── todo               Plain-text list of known issues / outstanding work
│
├── src/
│   ├── root.zig       Public API surface — re-exports everything Claude code
│   │                  should import as "paramlib"
│   ├── main.zig       Binary entry point (stub)
│   ├── benchmark.zig  Microbenchmark binary
│   ├── tests.zig      Test runner — refAllDecls over all private modules
│   │
│   ├── api/
│   │   └── database.zig   ParamDatabase — the high-level public struct callers
│   │                       use; wraps the store + source list + runtime source
│   │
│   └── private/           Internal implementation; not part of the public API
│       ├── cpp/
│       │   ├── lexer.zig      Tokenizer + LineTable
│       │   ├── parser.zig     Recursive-descent parser → ClassAst
│       │   ├── ast.zig        AST node types (ClassAst, ParameterAst, ValueAst …)
│       │   └── utils/log.zig  Diagnostic / error reporting helpers
│       │   └── tests/         Sample .cpp / .rvmat fixtures used in tests
│       │
│       ├── slabs/             "Data slab" storage types (fixed-size pool per type)
│       │   ├── array.zig      ArrayData / ArrayPool
│       │   ├── class.zig      ClassData / ClassPool / ClassStorage iterator
│       │   ├── enum.zig       EnumData / EnumPool  (partially wired)
│       │   ├── parameter.zig  ParameterData / ParameterPool / ParameterStorage
│       │   └── source.zig     SourceData / SourcePool / SourceStorage
│       │
│       ├── data/
│       │   ├── storage.zig    ParamAllocator — central store; owns all slab pools
│       │   └── value.zig      Value types used by storage
│       │
│       ├── tree/
│       │   ├── factory.zig    createClass / createParameter / getOrCreateParameter
│       │   ├── query.zig      lookupParameterByPathHash, findChildByNameHash, etc.
│       │   └── references.zig retainHandle / releaseHandle ref-counting helpers
│       │
│       └── utils/
│           ├── handles.zig    Handle<T> — typed, generation-checked smart pointer
│           ├── hasher.zig     IncrementalHasher (WyHash-based path hashing)
│           ├── identifiers.zig TypedId — compile-time–typed integer IDs per storage type
│           ├── memory.zig     SlabPool — generic slab allocator
│           ├── paths.zig      PathSegment / SegmentInit helpers
│           └── strings.zig    StringPool — intern strings, return typed IDs
│
└── lsp/
    ├── lsp.zig     All LSP logic: message dispatch, hover, completion, symbols,
    │               semantic tokens, diagnostics, inlay hints, go-to-definition,
    │               references, SchemaState (CfgSchemas parsing)
    ├── native.zig  Stdio transport entry point for native binary
    └── web.zig     WASM-exported entry points for VS Code web extension

```


---

## Build commands

```sh
# Standard full build (release, with VS Code extension)
zig build install -Doptimize=ReleaseFast -Dvscode=true -freference-trace=12

# Run all tests
zig build test

# Run the native LSP server directly
zig build lsp

# Skip the bun check (useful in CI where bun may be absent)
zig build install -Doptimize=ReleaseFast -Dvscode=true -Dcheck-bun=false -freference-trace=12
```

---

## Architecture at a glance

### Data flow for parsing a file

```
raw text [:0]const u8
  │
```

▼ Tokenizer (lexer.zig) produces Token stream (kind + data + byte offset) │ ▼ parseSource (parser.zig) returns ClassAst ← pure AST, no allocations beyond ArrayList members │ ▼ factory.zig helpers createClass / getOrCreateParameter → write into ParamAllocator │ ▼ ParamAllocator (storage.zig) holds SlabPool, SlabPool, StringPool, … all addressable via typed handles

```

### Key types to know

TypeFileRole`ParamDatabasesrc/api/database.zig`Top-level API; own one per document set`ParamAllocatorsrc/private/data/storage.zig`Arena-like store for all slab data`ClassAstsrc/private/cpp/ast.zig`Parse-time class node (temporary, deinit after use)`ClassDatasrc/private/slabs/class.zig`Persistent class record inside the slab pool`ParameterDatasrc/private/slabs/parameter.zig`Persistent parameter record`ClassHandle` / `ParameterHandleutils/handles.zig`Generation-checked typed pointers`IncrementalHasherutils/hasher.zig`Build path hashes: `load(parent).updateSep().update(name).final()SchemaStatelsp/lsp.zig`Parsed `CfgSchemas` rules driving LSP completion + inlay hints

### Handle / identifier pattern

Every storage type has a companion `TypedId` and `Handle`:

```zig
// From class.zig
pub const ClassIdentifier = identifiers.TypedId("Class", .clazz, *ClassData, *const ClassData);
pub const ClassHandle     = handles.Handle(ClassIdentifier);
```

Handles carry a **generation counter** — stale handles fail validation. Always resolve via `handle.validateHandle(store)` before dereferencing.

### SlabPool

`memory.SlabPool(T, Identifier, SlabSize)` allocates `T` values in fixed-size slabs and hands back typed identifiers. Call `pool.acquire(alloc)` to get an `{index, ptr}` pair; call `pool.release(alloc, index)` to free. The `current_slab` caching is noted in `todo` as inefficient — see known issues.

---

## LSP features (lsp/lsp.zig)

The LSP handles these capabilities:

- `textDocument/hover` — class name + member count, or parameter type + value
- `textDocument/documentSymbol` — flat list of all class + param names
- `textDocument/definition` — jump to base-class reference or inherited parameter definition
- `textDocument/references` — all subclasses overriding a base / all param overrides
- `textDocument/semanticTokens/full` — keyword / comment / identifier / string / operator / number
- `textDocument/completion` — identifier completions; `stringCompletions` from `CfgSchemas`
- `textDocument/inlayHint` — array element labels from `CfgSchemas.arrayInlays`
- `$/paramlib/listSchemaClasses` — custom method listing known `CfgSchemas` class names

`SchemaState` is rebuilt from the open documents whenever a save/open/change event fires. It reads `CfgSchemas { ClassName { stringCompletions = ...; arrayInlays = ...; } }` out of the parsed AST.

**Forward declarations across files** are supported. A schema file may forward-declare a base class with no body (`class DayZ;`) and then inherit from it:

```cpp
class CfgSchemas {
    class DayZ;                  // defined in another open document
    class MyProject : DayZ {
        // project-specific additions
    };
};
```

`extractFromDocuments` does two parse passes over all open documents to resolve this:

- **Pass 1** – builds a `name → SchemaState` map for every `CfgSchemas` child class that has a body. Classes whose base is a forward decl receive an empty base state for now.
- **Pass 2** – re-parses all documents; rebuilds any class whose forward-declared base is now in the map (handles any document-insertion order); collects all class names for `schemaClasses`; selects the last body-having class as the active schema.

`updateFromContent` (single-file path) passes an empty named map — forward decls to other files simply resolve to `.empty` there.

---

## Testing

Tests are written **inline in the same source file** they test — never in separate test files. Use standard Zig `test "..."` blocks directly alongside the code being tested. `src/tests.zig` collects them all via `std.testing.refAllDecls`.

There are also inline bench tests (prefixed `bench -`) that print ns/iter to stderr. They run under the normal test runner but are not assertions — they are timing-only.

Test fixtures (sample `.cpp` / `.rvmat` files) live in `src/private/cpp/tests/`.

---

## Known issues / todo highlights

See `todo` for the full list. Most important items:

1. `deleteClass` **reference guard missing** — freeing a class that is someone else's base is not guarded. Add `if (data.references.load(.monotonic) > 1) return error.ClassInUse;`.
2. `cpp` **parser is incomplete** — `@expr` mode, `#line` directives, string continuation, and duplicate-name detection are all in `todo`.
3. **Binary format parser is not implemented** — `Par\0` magic + v8 format.
4. `retain/release` **doesn't walk the base chain** — ref-counts on base classes are undercounted.
5. `SlabPool.acquire` **is O(slabs)** — `current_slab` field should cache the last slab with free space.
6. `ParamDatabase` **doesn't expose** `mergeFrom` — callers must reach into `store` directly.
7. **Enum storage not wired** — `EnumInit` / `EnumData` are incomplete; `storage.zig` panics on `.enumeration` in `alloc`.

---

## Editing guidance

- **Public API changes** → edit `src/root.zig` to re-export new modules.
- **New slab type** → add `Data`, `Init`, `Pool`, `Identifier`, `Handle` in a new `slabs/*.zig`, register the pool in `ParamAllocator`, add an `alloc` branch in `storage.zig`.
- **LSP features** → all logic lives in `lsp/lsp.zig`; `native.zig` and `web.zig` are thin entry-point wrappers that call into it.
- **Path hashing** → always use `IncrementalHasher.load(parentHash).updateSep().update(name).final()` so hashes are consistent with `pathToId` lookups.
- **Avoid allocating in the parser** — `ClassAst` uses `ArrayList` only for member lists; it is always `deinit`-ed after factory conversion. Don't store raw pointers into it after `deinit`.
- **Sentinel-terminated source strings** — `lexer.Tokenizer.init` takes `[:0]const u8`. When calling the parser from the LSP or tests, `dupeZ` the source first.
