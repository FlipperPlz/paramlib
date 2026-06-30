import * as vscode from 'vscode';
import {
  LanguageClient,
} from 'vscode-languageclient/browser';
import { bootstrapExtension } from '../extensionBootstrap';

let client: LanguageClient | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  const { clientOptions, state } = bootstrapExtension(context);

  const serverMain = vscode.Uri.joinPath(context.extensionUri, 'dist', 'web', 'server.js');
  const worker = new Worker(serverMain.toString(true));

  client = new LanguageClient('paramlibLsp', 'ParamLib LSP', clientOptions, worker);

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
