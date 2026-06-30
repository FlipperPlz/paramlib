import * as path from 'path';
import * as vscode from 'vscode';
import {
  LanguageClient,
  TransportKind,
} from 'vscode-languageclient/node';
import type { ServerOptions } from 'vscode-languageclient/node';
import { bootstrapExtension } from './extensionBootstrap';

let client: LanguageClient | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  const { clientOptions, state } = bootstrapExtension(context);

  const serverModule = context.asAbsolutePath(path.join('dist', 'server.js'));
  const serverOptions: ServerOptions = {
    run: { module: serverModule, transport: TransportKind.ipc },
    debug: {
      module: serverModule,
      transport: TransportKind.ipc,
      options: { execArgv: ['--nolazy', '--inspect=6009'] },
    },
  };

  client = new LanguageClient(
    'paramlibLsp',
    'ParamLib LSP',
    serverOptions,
    clientOptions,
  );

  await client.start();
  state.schemaSystem.attachClient(client);

  context.subscriptions.push({
    dispose: () => { void client?.stop(); },
  });
}

export async function deactivate(): Promise<void> {
  await client?.stop();
  client = undefined;
}
