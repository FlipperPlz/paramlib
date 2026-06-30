import * as vscode from 'vscode';
import type {
  CancellationToken,
} from 'vscode';
import type { Middleware } from 'vscode-languageclient';
import type { WasmModuleLoader, WasmModuleHandle } from './wasmLoader';
import { callWasm } from './wasmLoader';
import { mergeLspResults } from './lspMerge';
import { buildCapabilitiesPatch } from './lspCapabilities';
import type { SchemaSystem } from './schemaSystem';

export function createMergingMiddleware(
  getLoader: () => WasmModuleLoader | undefined,
  getSchemaSystem: () => SchemaSystem | undefined,
): Middleware {
  const hintsCache = new Map<string, any[]>();

  return {
    async sendRequest(type: any, params: any, token: CancellationToken, next: any) {
      const method = typeof type === 'string' ? type : type.method;
      const defaultResult = await next(type, params, token);
      if (token.isCancellationRequested) return defaultResult;

      const loader = getLoader();
      if (!loader) return defaultResult;

      if (method === 'initialize') {
        const registered = new Set<string>();
        for (const handle of loader.getAll().values()) {
          for (const key of Object.keys(handle.exports)) {
            if (typeof handle.exports[key] === 'function') registered.add(key);
          }
        }
        const patch = buildCapabilitiesPatch(Array.from(registered));
        const res = defaultResult as any;
        res.capabilities = { ...(res.capabilities ?? {}), ...patch };
        return res;
      }

      const additions: string[] = [];
      const uri = params?.textDocument?.uri;
      const hints = uri ? (hintsCache.get(uri.toString()) ?? []) : [];

      const schemaSystem = getSchemaSystem();
      const schema = uri ? schemaSystem?.schemas.get(vscode.Uri.parse(uri.toString()).fsPath) : undefined;

      const handlesToCall: WasmModuleHandle[] = [];
      if (schema) {
        const requiredWasm = new Set(schema.parserRules.map(r => r.wasm_source));
        for (const id of requiredWasm) {
          const handle = loader.get(id);
          if (handle) handlesToCall.push(handle);
        }
      } else {
        for (const handle of loader.getAll().values()) {
          handlesToCall.push(handle);
        }
      }

      for (const handle of handlesToCall) {
        const extra = callWasm(handle, method, { params, hints });
        if (extra) additions.push(extra);
      }

      const merged = mergeLspResults(method, defaultResult, additions, { hints });

      if (method === 'textDocument/inlayHint') {
        if (uri) hintsCache.set(uri.toString(), merged as any[]);
      }

      return merged;
    },

    async sendNotification(type: any, params: any, next: any) {
      const method = typeof type === 'string' ? type : type.method;
      const loader = getLoader();

      if (loader) {
        const uri = params?.textDocument?.uri;
        const hints = uri ? (hintsCache.get(uri.toString()) ?? []) : [];
        
        const schemaSystem = getSchemaSystem();
        const schema = uri ? schemaSystem?.schemas.get(vscode.Uri.parse(uri.toString()).fsPath) : undefined;

        const handlesToCall: WasmModuleHandle[] = [];
        if (schema) {
          const requiredWasm = new Set(schema.parserRules.map(r => r.wasm_source));
          for (const id of requiredWasm) {
            const handle = loader.get(id);
            if (handle) handlesToCall.push(handle);
          }
        } else {
          for (const handle of loader.getAll().values()) {
            handlesToCall.push(handle);
          }
        }

        for (const handle of handlesToCall) {
          callWasm(handle, method, { params, hints });
        }
      }

      return next(type, params);
    },
  };
}
