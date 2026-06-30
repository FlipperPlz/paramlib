import * as vscode from 'vscode';

export interface WasmHostImports {
  wasm_log(ptr: number, len: number): void;
  reportError(ptr: number, len: number): void;
}

export interface WasmModuleExports extends WebAssembly.Exports {
  alloc?(len: number): number;
  free?(ptr: number, len: number): void;
  parse?(in_ptr: number, in_len: number, out_ptr: number, out_max: number): number;
  deinit?(): void;

  [method: string]: any;
}

export interface WasmModuleHandle {
  readonly id: string;
  readonly exports: WasmModuleExports;
}

export class WasmModuleLoader implements vscode.Disposable {
  private readonly cache = new Map<string, WasmModuleHandle>();

  constructor(private readonly extensionUri: vscode.Uri) {}

  async load(moduleId: string): Promise<WasmModuleHandle> {
    const cached = this.cache.get(moduleId);
    if (cached) return cached;

    const uri = vscode.Uri.joinPath(
      this.extensionUri,
      'dist', 'wasm', `${moduleId}.wasm`,
    );

    let bytes: Uint8Array;
    try {
      bytes = await vscode.workspace.fs.readFile(uri);
    } catch (err) {
      throw new Error(`WasmModuleLoader: failed to read "${moduleId}.wasm": ${String(err)}`);
    }

    const output = new class {
      private readonly decoder = new TextDecoder();
      private memory: WebAssembly.Memory | undefined;

      bindMemory(mem: WebAssembly.Memory) { this.memory = mem; }

      readString(ptr: number, len: number): string {
        if (!this.memory) return `<ptr=${ptr} len=${len}>`;
        return this.decoder.decode(new Uint8Array(this.memory.buffer, ptr, len));
      }
    }();

    const imports: WebAssembly.Imports = {
      env: {
        wasm_log: (ptr: number, len: number) => {
          console.log(`[wasm:${moduleId}]`, output.readString(ptr, len));
        },
        reportError: (ptr: number, len: number) => {
          console.error(`[wasm:${moduleId}] error:`, output.readString(ptr, len));
        },
      } satisfies WasmHostImports,
    };

    let result: WebAssembly.WebAssemblyInstantiatedSource;
    try {
      result = await WebAssembly.instantiate(bytes as BufferSource, imports);
    } catch (err) {
      throw new Error(`WasmModuleLoader: failed to instantiate "${moduleId}": ${String(err)}`);
    }

    const exports = result.instance.exports as WasmModuleExports;

    if (exports.memory instanceof WebAssembly.Memory) {
      output.bindMemory(exports.memory);
    }

    const handle: WasmModuleHandle = { id: moduleId, exports };
    this.cache.set(moduleId, handle);
    return handle;
  }

  get(moduleId: string): WasmModuleHandle | undefined {
    return this.cache.get(moduleId);
  }

  getAll(): ReadonlyMap<string, WasmModuleHandle> {
    return this.cache;
  }

  async unload(moduleId: string): Promise<void> {
    const handle = this.cache.get(moduleId);
    if (!handle) return;
    handle.exports.deinit?.();
    this.cache.delete(moduleId);
  }

  async disposeAll(): Promise<void> {
    await Promise.all([...this.cache.keys()].map((id) => this.unload(id)));
  }

  dispose(): void {
    void this.disposeAll();
  }
}

export function callWasm(
  handle: WasmModuleHandle,
  method: string,
  data: any,
): string | null {
  const { exports, id } = handle;

  const candidates = [
    method,
    method.replace(/\//g, '_'),
  ];

  let fn: ((...args: any[]) => any) | undefined;
  for (const name of candidates) {
    if (typeof exports[name] === 'function') {
      fn = exports[name] as (...args: any[]) => any;
      break;
    }
  }
  if (!fn) return null;

  const { alloc, free } = exports;
  const mem = exports.memory as WebAssembly.Memory | undefined;
  if (!alloc || !mem) return null;

  const inputBytes = new TextEncoder().encode(JSON.stringify(data));
  const outMax = 1024 * 1024;

  const inPtr = alloc(inputBytes.byteLength);
  new Uint8Array(mem.buffer).set(inputBytes, inPtr);

  const outPtr = alloc(outMax);

  try {
    const written: number = fn(inPtr, inputBytes.byteLength, outPtr, outMax);
    if (typeof written !== 'number' || written <= 0) return null;
    return new TextDecoder().decode(new Uint8Array(mem.buffer, outPtr, written));
  } catch (err) {
    console.error(`[paramlib:wasm] "${id}" failed on "${method}":`, err);
    return null;
  } finally {
    free?.(inPtr, inputBytes.byteLength);
    free?.(outPtr, outMax);
  }
}
