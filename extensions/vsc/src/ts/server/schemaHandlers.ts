import { Connection, TextDocuments, WorkspaceFolder } from 'vscode-languageserver';
import { TextDocument } from 'vscode-languageserver-textdocument';
import { LSP_GET_SCHEMA, LSP_PUSH_SCHEMAS } from '../schemaSystem';
import type { SchemaState } from '../schemaSystem';
import * as path from 'path';
import * as fs from 'fs/promises';

interface SchemaForPathParams {
  path: string;
}

interface SchemaDescriptor {
  uri: string;
  content: string;
  className?: string | null;
}

interface PushSchemasParams {
  schemas: { path: string; state: SchemaState }[];
}

export function registerSchemaHandlers(
  connection: Connection,
  _documents: TextDocuments<TextDocument>,
): void {
  const schemasByPath = new Map<string, SchemaState>();

  connection.onRequest(
    LSP_GET_SCHEMA,
    async (params: SchemaForPathParams): Promise<SchemaDescriptor | null> => {
      const folders = await connection.workspace.getWorkspaceFolders();
      if (!folders) return null;

      const targetPath = path.resolve(params.path);

      const folder = folders.find((f) => targetPath.startsWith(new URL(f.uri).pathname));
      if (!folder) return null;

      const folderPath = new URL(folder.uri).pathname;

      let curDir = path.dirname(targetPath);
      const stopDir = path.resolve(folderPath);

      const candidates = ['schema.cpp', 'config.cpp'];

      while (true) {
        for (const name of candidates) {
          const candidatePath = path.join(curDir, name);
          try {
            const content = await fs.readFile(candidatePath, 'utf-8');
            return {
              uri: 'file://' + candidatePath,
              content,
              className: null,
            };
          } catch {
          }
        }

        if (curDir === stopDir) break;
        const parent = path.dirname(curDir);
        if (parent === curDir) break;
        curDir = parent;
      }

      return null;
    },
  );

  connection.onNotification(
    LSP_PUSH_SCHEMAS,
    (params: PushSchemasParams): void => {
      for (const entry of params.schemas) {
        schemasByPath.set(entry.path, entry.state);
      }
      connection.console.log(
        `[paramlib] received ${params.schemas.length} schema(s); ` +
        `store now has ${schemasByPath.size} entry(ies).`,
      );
    },
  );
}
