import type {
  Connection,
  InitializeParams,
  InitializeResult,
} from 'vscode-languageserver';
import {
  TextDocuments,
  TextDocumentSyncKind,
} from 'vscode-languageserver';
import { TextDocument } from 'vscode-languageserver-textdocument';
import { registerSchemaHandlers } from './schemaHandlers';

export function startServer(
  createConnection: () => Connection,
): void {
  const connection = createConnection();
  const documents = new TextDocuments(TextDocument);

  connection.onInitialize((_params: InitializeParams): InitializeResult => {
    return {
      capabilities: {
        textDocumentSync: TextDocumentSyncKind.Incremental,
        completionProvider: { resolveProvider: false },
        hoverProvider: false,
      },
    };
  });

  registerSchemaHandlers(connection, documents);

  documents.listen(connection);
  connection.listen();
}
