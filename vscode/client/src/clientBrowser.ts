import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
} from 'vscode-languageclient/browser';

declare const __DEV_MODE__: boolean;
declare const __SCHEMAS_URL__: string;

let client: LanguageClient;
let ctx: vscode.ExtensionContext;

async function listBuiltinSchemas(): Promise<string[]> {
    const schemasUri = vscode.Uri.joinPath(ctx.extensionUri, 'schemas');
    let localNames: string[] = [];
    try {
        const entries = await vscode.workspace.fs.readDirectory(schemasUri);
        localNames = entries
            .filter(([n, t]) => t === vscode.FileType.File && n.endsWith('.json'))
            .map(([n]) => n.slice(0, -5));
    } catch { }

    if (__DEV_MODE__ || localNames.length > 0) return localNames;

    try {
        const res = await fetch(__SCHEMAS_URL__);
        if (!res.ok) return [];
        const html = await res.text();
        const matches = [...html.matchAll(/href="([^"]+\.json)"/g)];
        return matches.map(m => m[1].replace(/\.json$/, ''));
    } catch { return []; }
}

async function resolveAndSendSchema(value: string): Promise<void> {
    try {
        let text: string;
        if (value.startsWith('builtin:')) {
            const name = value.slice(8);
            if (__DEV_MODE__) {
                const uri = vscode.Uri.joinPath(ctx.extensionUri, 'schemas', `${name}.json`);
                text = new TextDecoder().decode(await vscode.workspace.fs.readFile(uri));
            } else {
                try {
                    const uri = vscode.Uri.joinPath(ctx.extensionUri, 'schemas', `${name}.json`);
                    text = new TextDecoder().decode(await vscode.workspace.fs.readFile(uri));
                } catch {
                    const res = await fetch(`${__SCHEMAS_URL__}${name}.json`);
                    if (!res.ok) throw new Error(`CDN fetch failed: HTTP ${res.status}`);
                    text = await res.text();
                }
            }
        } else if (value.startsWith('http://') || value.startsWith('https://')) {
            const res = await fetch(value);
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            text = await res.text();
        } else {
            text = new TextDecoder().decode(
                await vscode.workspace.fs.readFile(vscode.Uri.file(value)),
            );
        }
        void client.sendNotification('$/paramlib/schemaUpdate', { content: text });
    } catch (e) { console.error('[paramlib] resolveAndSendSchema failed:', e); }
}

function getEffectiveSchema(): string {
    const cfg = vscode.workspace.getConfiguration('paramlib');
    const schemaFile: string = cfg.get('schemaFile', 'builtin:dayz');
    if (schemaFile === 'custom') return cfg.get('customSchemaPath', '');
    return schemaFile;
}

export function activate(context: vscode.ExtensionContext): void {
    ctx = context;

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

    void client.start().then(async () => {
        const sf = getEffectiveSchema();
        if (sf) await resolveAndSendSchema(sf);

        context.subscriptions.push(
            vscode.workspace.onDidChangeConfiguration(async e => {
                if (e.affectsConfiguration('paramlib.schemaFile') ||
                    e.affectsConfiguration('paramlib.customSchemaPath')) {
                    const updated = getEffectiveSchema();
                    if (updated) await resolveAndSendSchema(updated);
                }
            }),
        );
    });

    context.subscriptions.push(client);
}

export function deactivate(): Thenable<void> | undefined {
    return client?.stop();
}
