import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
} from 'vscode-languageclient/browser';

let client: LanguageClient;

export function activate(context: vscode.ExtensionContext): void {
    const serverWorkerUri = vscode.Uri.joinPath(
        context.extensionUri,
        'server', 'dist', 'serverBrowser.js',
    );

    const worker = new Worker(serverWorkerUri.toString());

    const clientOptions: LanguageClientOptions = {
        documentSelector: [
            { language: 'paramlib' },
            { pattern: '**/config.cpp' },
            { pattern: '**/*.rvmat' },
        ],
        synchronize: {},
    };

    client = new LanguageClient(
        'paramlib-lsp',
        'ParamLib Language Server',
        clientOptions,
        worker,
    );

    client.start();
    context.subscriptions.push(client);
}

export function deactivate(): Thenable<void> | undefined {
    return client?.stop();
}
