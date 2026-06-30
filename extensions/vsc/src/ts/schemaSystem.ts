import * as vscode from 'vscode';
import type { WasmModuleLoader } from './wasmLoader';
import { callWasm } from './wasmLoader';

// ── Schema types (shared with the server side via protocol) ─────────────────

export interface StringCompletionRule {
  path: string;
  values: string[];
  source?: string;
}

export interface ArrayInlaysRule {
  path: string;
  labels: string[];
  source?: string;
}

export interface ParserRule {
  pattern: string;
  wasm_source: string;
  source?: string;
}

export interface ParamDocRule {
  path: string;
  doc: string;
  source?: string;
}

export interface SchemaState {
  stringCompletions: StringCompletionRule[];
  arrayInlays: ArrayInlaysRule[];
  parserRules: ParserRule[];
  paramDocs: ParamDocRule[];
  schemaClasses: string[];
  projectName: string;
  selectedClass: string;
  base_class: string;
  pushedSchemas: Record<string, SchemaState>;
}
export interface SchemaClient {
  sendRequest<T>(method: string, params: unknown): Promise<T>;
  sendNotification(method: string, params: unknown): Promise<void> | void;
}


export const LSP_GET_SCHEMA = '$/paramlib/getSchemaForPath' as const;
export const LSP_PUSH_SCHEMAS = '$/paramlib/schemas' as const;

interface SchemaDescriptor {
  uri: string;
  content: string;
  className?: string | null;
}

export class SchemaSystem implements vscode.Disposable {
  private client: SchemaClient | undefined;
  private readonly schemasByPath = new Map<string, SchemaState>();

  constructor(private readonly wasmLoader: WasmModuleLoader) {}

  attachClient(client: SchemaClient): void {
    this.client = client;
  }

  async resolveForDocument(document: vscode.TextDocument): Promise<void> {
    if (!this.client) return;

    const desc = await this.client.sendRequest<SchemaDescriptor | null>(
      LSP_GET_SCHEMA,
      { path: document.uri.fsPath },
    ).catch(err => {
      console.error(`[SchemaSystem] failed to get schema for ${document.uri.fsPath}:`, err);
      return null;
    });

    if (!desc) return;

    try {
      const handle = await this.wasmLoader.load('core');
      const exp = handle.exports as any;
      const mem = exp.memory as WebAssembly.Memory | undefined;
      if (!mem || typeof exp.alloc !== 'function' || typeof exp.free !== 'function' || typeof exp.schemaUpdate !== 'function') {
        console.error('[SchemaSystem] core WASM missing required exports');
      } else {
        const enc = new TextEncoder();
        const uriBytes = enc.encode(desc.uri);
        const contentBytes = enc.encode(desc.content);
        const classBytes = enc.encode(desc.className ?? '');
        const uriPtr = exp.alloc(uriBytes.byteLength);
        const contentPtr = exp.alloc(contentBytes.byteLength);
        const classPtr = exp.alloc(classBytes.byteLength);
        new Uint8Array(mem.buffer).set(uriBytes, uriPtr);
        new Uint8Array(mem.buffer).set(contentBytes, contentPtr);
        new Uint8Array(mem.buffer).set(classBytes, classPtr);
        try {
          exp.schemaUpdate(uriPtr, uriBytes.byteLength, contentPtr, contentBytes.byteLength, classPtr, classBytes.byteLength);
        } finally {
          exp.free(uriPtr, uriBytes.byteLength);
          exp.free(contentPtr, contentBytes.byteLength);
          exp.free(classPtr, classBytes.byteLength);
        }
      }
    } catch (e) {
      console.error('[SchemaSystem] failed to update core schema:', e);
    }

    const placeholder: SchemaState = {
      stringCompletions: [],
      arrayInlays: [],
      parserRules: [],
      paramDocs: [],
      schemaClasses: [],
      projectName: '',
      selectedClass: '',
      base_class: '',
      pushedSchemas: {},
    };
    this.schemasByPath.set(document.uri.fsPath, placeholder);

    await this.pushSchemas();
  }

  async pushSchemas(): Promise<void> {
    if (!this.client) return;
    await this.client.sendNotification(LSP_PUSH_SCHEMAS, {
      schemas: [...this.schemasByPath.entries()].map(([path, state]) => ({ path, state })),
    });
  }

  get schemas(): ReadonlyMap<string, SchemaState> {
    return this.schemasByPath;
  }

  dispose(): void {
    this.schemasByPath.clear();
    this.client = undefined;
  }
}
