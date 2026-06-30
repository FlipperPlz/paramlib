import * as vscode from 'vscode';
import type {
  LanguageClientOptions,
  Middleware,
} from 'vscode-languageclient';
import { WasmModuleLoader } from './wasmLoader';
import { SchemaSystem } from './schemaSystem';
import { CurrentDocumentTracker } from './currentDocument';
import { createMergingMiddleware } from './lspClient';

export interface ExtensionState {
  readonly wasmLoader: WasmModuleLoader;
  readonly schemaSystem: SchemaSystem;
}
export function bootstrapExtension(
  context: vscode.ExtensionContext,
): { clientOptions: LanguageClientOptions; state: ExtensionState } {
  const wasmLoader = new WasmModuleLoader(context.extensionUri);
  const schemaSystem = new SchemaSystem(wasmLoader);
  const docTracker = new CurrentDocumentTracker();

  context.subscriptions.push(
    docTracker,
    schemaSystem,
    wasmLoader,
  );

  context.subscriptions.push(
    docTracker.onDidChangeCurrentDocument((doc) => {
      if (doc) {
        void schemaSystem.resolveForDocument(doc);
      }
    }),
  );

  const middleware: Middleware = createMergingMiddleware(
    () => wasmLoader,
    () => schemaSystem,
  );

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: 'file', language: 'armaConfig' }],
    middleware,
  };

  return { clientOptions, state: { wasmLoader, schemaSystem } };
}
