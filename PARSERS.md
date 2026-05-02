# Embedded Parser System — Complete Guide

The paramlib LSP supports **embedded WASM-based parsers** defined directly in your schema file. These parsers can enrich inlay hints, implement custom LSP handlers, and provide dynamic value rendering based on parameter values or text patterns.

## Quick Start

### 1. Define Parser Rules in Your Schema

Create or edit your `CfgSchemas` in a schema file (e.g., `config.cpp`):

```cpp
class CfgSchemas {
    class DayZ {
        // Glob-based parameter value parser
        // Matches parameter paths and calls the WASM parser with the value
        parsers[] += {
            { "Item.*.color",         "color.wasm" },     // glob pattern
            { "Vehicle.*.position",   "vector3.wasm" },  // matches nested paths
        };

        // Regex-based source text scanner
        // Matches patterns in raw source and calls WASM parser on capture groups
        parsers[] += {
            { "MACRO$$ (.*) $$",      "macro.wasm" },    // regex pattern
            { "@expr\\((.*)\\)",      "expr.wasm" },     // captures first group
        };
    };
};
```

### 2. Load or Write Your WASM Parser

Every WASM parser module must export a **`parse` function** with this signature:

```c
// WASM parser ABI — required export
int parse(int32_t input_ptr, int32_t input_len, int32_t out_ptr, int32_t out_max);
```

**Parameters:**
- `input_ptr`, `input_len` — pointer and length of the input string in WASM memory
- `out_ptr`, `out_max` — pointer and max output length for the result

**Returns:**
- `>= 0` — number of bytes written to `out_ptr` (the inlay hint text)
- `-1` — parse error; no hint is shown

**C Example:**

```c
#include <string.h>
#include <stdio.h>

// For a color value like "1 0 0", return a colored preview
int parse(int32_t input_ptr, int32_t input_len, int32_t out_ptr, int32_t out_max) {
    // In a real implementation, you would:
    // 1. Read input bytes from memory[input_ptr..input_ptr+input_len]
    // 2. Parse the input (e.g., RGB values)
    // 3. Generate output (e.g., a color swatch representation)
    // 4. Write output bytes to memory[out_ptr..out_ptr+out_max]
    // 5. Return the number of bytes written

    // Example: return "🟥" for a red color
    const char* result = "[RGB]";
    int len = strlen(result);
    if (len > out_max) return -1;
    memcpy((void*)out_ptr, result, len);
    return len;
}
```

### 3. Optional: Implement Custom LSP Handlers

In addition to `parse`, you can export any LSP handler function to intercept/override LSP requests:

```c
// Example: custom textDocument/documentColor handler
int textDocument_documentColor(int32_t params_ptr, int32_t params_len, int32_t out_ptr, int32_t out_max) {
    // params_ptr points to JSON: { "params": <LSP params>, "hints": <PrecomputedParserHint[]> }
    // Write a JSON LSP result to out_ptr
    // Return number of bytes written, or -1 on error
    ...
}
```

Export name resolution:
- Full mangled: `"textDocument/documentColor"` → `textDocument_documentColor`
- Short form: `"textDocument/documentColor"` → `documentColor` (fallback)

## Architecture

### Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ TypeScript (vscode/server/src/serverNode.ts)                    │
└────────┬──────────────────────────┬──────────────────────────────┘
         │                          │
         │ 1. Parse schema          │ 5. Request rules & params
         │                          │
┌────────▼──────────────────────────▼──────────────────────────────┐
│ Zig LSP (lsp/lsp.zig)                                            │
│  • Parses CfgSchemas from open documents                         │
│  • Stores parserRules[] in SchemaState                           │
│  • Handles $/paramlib/getParserRules request                     │
│  • Handles $/paramlib/getDocumentParams request                  │
│  • Merges document hints in inlayHints response                  │
└────────┬──────────────────────────────────────────────────────────┘
         │
         │ 2. Send rules to TS
         │
┌────────▼──────────────────────────────────────────────────────────┐
│ ParserManager (vscode/server/src/parser.ts)                      │
│  • Loads & instantiates WASM modules                             │
│  • Matches rules: glob patterns (params) vs regex (source)       │
│  • Calls parse() on each match                                   │
│  • Invokes custom LSP handlers from WASM exports                 │
│  • Caches hints in documentHints map                             │
└────────┬──────────────────────────────────────────────────────────┘
         │
         │ 3. Send hints back to Zig
         │
         └──► $/paramlib/parserHints notification
             (Zig merges into SchemaState.documentHints)
```

### Type Definitions

All types are defined in `lsp/lsp.zig` and JSON-serializable:

**ParserRule** — A schema rule pairing a pattern and WASM module:
```zig
pub const ParserRule = struct {
    pattern: []const u8,      // glob (e.g. "**.color") or regex (e.g. "MACRO$$ (.*) $$")
    wasm_source: []const u8,  // path, URL, or "internal:name"
};
```

**DocumentParam** — A parameter from a parsed document:
```zig
pub const DocumentParam = struct {
    path: []const u8,             // dot-path (e.g. "CfgVehicles.Car.speed")
    value: []const u8,            // stringified value (e.g. "1.5")
    line: u32,                    // parameter name position
    character: u32,
    value_line: u32,              // value token position
    value_character: u32,
};
```

**PrecomputedParserHint** — A hint generated by a WASM parser:
```zig
pub const PrecomputedParserHint = struct {
    line: u32,                // inlay hint position
    character: u32,
    text: []const u8,         // the rich text to display
};
```

## Schema Syntax Examples

### Glob Parameter Matching

The simplest pattern type; matches parameter dot-paths:

```cpp
class CfgSchemas {
    class MySchema {
        parsers[] += {
            // Exact path
            { "Weapon.damage", "damage.wasm" },
            
            // Single-segment wildcard (no dots)
            { "Item.*.color", "color.wasm" },
            
            // Multi-segment wildcard
            { "**.position", "vector3.wasm" },
            
            // Combination
            { "CfgVehicles.*.interior.*.material", "pbr.wasm" },
        };
    };
};
```

### Regex Source Matching

Use parentheses `(...)` or `$$` delimiters to enable regex mode:

```cpp
class CfgSchemas {
    class MySchema {
        parsers[] += {
            // Regex with capture group (capture group 1 becomes input)
            { "MACRO$$ ([A-Z_]+) $$", "macro.wasm" },
            
            // Alternative: without delimiters, but must have parens
            { "#define\\s+(\\w+)\\s+", "define.wasm" },
            
            // Full match becomes input if no capture group
            { "0x[0-9A-Fa-f]{6}", "hex_color.wasm" },
        };
    };
};
```

### Combining with Other Schema Features

```cpp
class CfgSchemas {
    class DayZ {
        // Schema completions
        stringCompletions[] = {
            {"Item.type", {"food", "weapon", "medical"}}
        };

        // Array element labels
        arrayInlays[] = {
            {"**.color[4]", {"red", "green", "blue", "alpha"}}
        };

        // Embedded parsers
        parsers[] = {
            {"Item.*.color", "color.wasm"},
            {"RGBA$$ (.*) $$", "color.wasm"}
        };
    };
};
```

## Custom LSP Handlers

Any WASM parser can export additional LSP handler functions. When an LSP request arrives, the ParserManager checks if any loaded parser exports a matching handler.

**Handler Signature:**

```c
// Input: JSON { "params": <LSP params>, "hints": <PrecomputedParserHint[]> }
// Output: JSON-serialized LSP result (or empty to pass through)
int handler_name(int32_t params_ptr, int32_t params_len, int32_t out_ptr, int32_t out_max);
```

**Example: Custom Color Provider**

```c
int textDocument_documentColor(int32_t params_ptr, int32_t params_len, int32_t out_ptr, int32_t out_max) {
    // Read LSP params from WASM memory
    // Extract URI and range from params
    // Scan source for colors and build response
    // Write JSON response to memory
    // Return length
    ...
}
```

## WASM Memory Management

The host (TypeScript) manages WASM memory on behalf of your parser:

```typescript
// Host calls parser with allocated buffers
const inPtr = allocFn(inputBytes.length);      // Host allocates
new Uint8Array(memory.buffer, inPtr, ...).set(inputBytes);  // Host copies in
const outPtr = allocFn(65536);                 // Host allocates output buffer
const outLen = parse(inPtr, inputBytes.length, outPtr, 65536);  // Parser writes
const result = new TextDecoder().decode(...);  // Host reads result
freeFn(inPtr, inputBytes.length);              // Host frees
freeFn(outPtr, 65536);
```

**Best Practices:**
1. Never assume how much memory is available — check `out_max`
2. Return `-1` if output would exceed `out_max`
3. Keep allocations small (64KB output buffer is typical)
4. Avoid allocating during `parse()` — pre-allocate in a setup function if needed

## Rule Processing Order

**Priority:**
1. Glob parameter rules are checked in schema order; first match wins
2. Regex rules are checked in schema order; **all matches are processed** (since they scan the entire source)
3. LSP handler rules are checked in schema order; first registered handler wins

**Caching:**
- Parser hints are cached per document URI in `SchemaState.documentHints`
- Cache is cleared whenever a document changes or schema is reloaded
- On schema reload, all open documents are re-processed

## Resolving WASM Sources

The `wasm_source` field in a rule can be:

- **Relative file path** (from the schema directory):  
  `"parsers/color.wasm"`

- **Absolute file path**:  
  `"/opt/gamemods/parsers/color.wasm"`

- **HTTP(S) URL**:  
  `"https://cdn.example.com/color.wasm"`

- **Internal parser** (bundled with the extension):  
  `"internal:color"` → resolves to `vscode/server/dist/parsers/color.wasm`

## Debugging

### Enabling Logs

In TypeScript, the ParserManager logs failures to `console.error`:

```
[paramlib] Failed to load <URL>: <error>
[paramlib] Invalid regex pattern: <pattern>
[paramlib] <WASM>: missing parse export
```

### Testing Your Parser

Use a simple C program to test your WASM parser outside the LSP:

```c
#include <stdio.h>
#include <string.h>

// Declare your parse function
extern int parse(int ptr_in, int len_in, int ptr_out, int len_out);

int main() {
    char input[] = "1 0 0";
    char output[256];
    int result = parse((int)&input, strlen(input), (int)&output, sizeof(output));
    if (result > 0) {
        fwrite(output, 1, result, stdout);
    }
    return 0;
}
```

Compile your Zig/Rust/C code to WASM and test the `parse` export directly using Node.js:

```javascript
const fs = require('fs');
const bytes = fs.readFileSync('color.wasm');
const { instance } = await WebAssembly.instantiate(bytes);
const parse = instance.exports.parse;
// Test parse...
```

## Common Patterns

### Color Swatch

```c
int parse(int32_t input_ptr, int32_t input_len, int32_t out_ptr, int32_t out_max) {
    // Input: "255 128 64" or "1 0.5 0.25"
    // Output: "🟦" or "#FF8040"
    ...
}
```

### Vector Display

```c
int parse(int32_t input_ptr, int32_t input_len, int32_t out_ptr, int32_t out_max) {
    // Input: array of 3 floats
    // Output: "vec3(1.0, 0.5, 0.0)"
    ...
}
```

### Macro Expansion

```c
int textDocument_documentColor(int32_t params_ptr, int32_t params_len, int32_t out_ptr, int32_t out_max) {
    // Input: LSP textDocument/documentColor params
    // Scan parsed hints from schema
    // Return ColorInformation[] for each color in the document
    ...
}
```

## Testing the Full System

1. **Create a test schema** with a `parsers[]` rule pointing to your WASM
2. **Place the WASM file** in an accessible location (or use a file:// URL)
3. **Open a paramlib document** in VS Code
4. **Configure schema file** in settings: `paramlib.schemaFile = "file://..."` or use the built-in selector
5. **Trigger document processing**:
   - Edit and save the document, or
   - Open Developer Tools (Cmd+Shift+J) and check `console.error` for parser logs
6. **Inspect inlay hints** — hover over parameters that match your rules to see the hints

## Troubleshooting

| Symptom | Cause | Solution |
|---------|-------|----------|
| Hints not appearing | WASM not loading | Check console.error for load failure; verify file path/URL |
| Hints appear but are blank | WASM `parse()` returning empty string | Debug WASM output — ensure it's writing valid UTF-8 |
| Rule not matching | Glob pattern syntax | Use `**` for multi-segment, `*` for single-segment (no dots) |
| Regex rule silent | Invalid regex pattern | Test regex in Node.js REPL; remember JS RegExp != Perl |
| Handler not called | Naming convention | Ensure export name matches: `textDocument_hover` or `hover` (fallback) |

---

For more examples, see the built-in DayZ schema at `vscode/schemas/dayz.cpp` and the parser implementation at `vscode/server/src/parser.ts`.

