import { ExtensionContext, Uri, window, workspace } from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    MessageTransports,
} from 'vscode-languageclient/node';
import { Wasm } from '@vscode/wasm-wasi';
// @ts-ignore
import { createStdioOptions, startServer } from '@vscode/wasm-wasi-lsp';

let client: LanguageClient | undefined;

export async function activate(context: ExtensionContext): Promise<void> {
    const wasm: Wasm = await Wasm.load();
    const channel = window.createOutputChannel('Paramlib LSP');

    const serverOptions: ServerOptions = async (): Promise<MessageTransports> => {
      const stdio = createStdioOptions()
      // @ts-ignore
      const wasmUri = Uri.joinPath(context.extensionUri, 'wasm', 'paramlib-lsp.wasm');
      const module  = await wasm.compile(wasmUri);

      const process = await wasm.createProcess('paramlib-lsp', module, {
        stdio,
        mountPoints: [{ kind: 'workspaceFolder' }],
      });

      return startServer(process);
    };

    const clientOptions: LanguageClientOptions = {
      documentSelector: [
        { scheme: 'file', language: 'paramlib' },
        { scheme: 'file', language: 'cpp' },
      ],
      outputChannel: channel,
    };

    client = new LanguageClient(
      'paramlibLsp',
      'Paramlib LSP',
      serverOptions,
      clientOptions,
    );

    await client.start();
    context.subscriptions.push({ dispose: () => client?.stop() });
}

export async function deactivate(): Promise<void> {
    await client?.stop();
}
