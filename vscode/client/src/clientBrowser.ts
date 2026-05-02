import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
} from 'vscode-languageclient/browser';

declare const __DEV_MODE__: boolean;
declare const __SCHEMAS_URL__: string;

let client: LanguageClient;
let ctx: vscode.ExtensionContext;

let lastSchemaClasses: string[] = [];

async function pickSchemaClass(): Promise<void> {
    if (lastSchemaClasses.length === 0) {
        void vscode.window.showInformationMessage('No schema loaded yet - schema class list is empty.');
        return;
    }
    const picked = await vscode.window.showQuickPick(lastSchemaClasses, {
        title: 'ParamLib: Select Schema Class',
        placeHolder: 'Choose a CfgSchemas class to activate',
    });
    if (picked === undefined) return;
    await vscode.workspace.getConfiguration('paramlib').update(
        'schemaClass', picked, vscode.ConfigurationTarget.Workspace,
    );
}

async function listBuiltinSchemas(): Promise<string[]> {
    const schemasUri = vscode.Uri.joinPath(ctx.extensionUri, 'schemas');
    let localNames: string[] = [];
    try {
        const entries = await vscode.workspace.fs.readDirectory(schemasUri);
        localNames = entries
            .filter(([n, t]) => t === vscode.FileType.File && n.endsWith('.cpp'))
            .map(([n]) => n.slice(0, -4));
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

async function resolveAndSendSchema(value: string, className?: string): Promise<void> {
    console.error(`[paramlib] resolveAndSendSchema: value=${value} className=${className}`);
    try {
        let text: string;
        if (value.startsWith('builtin:')) {
            const name = value.slice(8);
            if (__DEV_MODE__) {
                const uri = vscode.Uri.joinPath(ctx.extensionUri, 'schemas', `${name}.cpp`);
                text = new TextDecoder().decode(await vscode.workspace.fs.readFile(uri));
            } else {
                try {
                    const uri = vscode.Uri.joinPath(ctx.extensionUri, 'schemas', `${name}.cpp`);
                    text = new TextDecoder().decode(await vscode.workspace.fs.readFile(uri));
                } catch {
                    const res = await fetch(`${__SCHEMAS_URL__}${name}.cpp`);
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
        console.error(`[paramlib] sending schemaUpdate: ${text.length} chars`);
        void client.sendNotification('$/paramlib/schemaUpdate', { content: text, className });
    } catch (e) { console.error('[paramlib] resolveAndSendSchema failed:', e); }
}

function getEffectiveSchemaClass(): string | undefined {
    const cfg = vscode.workspace.getConfiguration('paramlib');
    const cls: string = cfg.get('schemaClass', '');
    return cls.length > 0 ? cls : undefined;
}

function getEffectiveSchema(): string {
    const cfg = vscode.workspace.getConfiguration('paramlib');
    const schemaFile: string = cfg.get('schemaFile', 'builtin:dayz');
    if (schemaFile === 'custom') return cfg.get('customSchemaPath', '');
    return schemaFile;
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
    ctx = context;

    const serverWorkerUri = vscode.Uri.joinPath(
        context.extensionUri,
        'server', 'dist', 'serverBrowser.js',
    );

    const serverWorkerUrl = await vscode.env.asExternalUri(serverWorkerUri);
    const worker = new Worker(serverWorkerUrl.toString());

    const wasmUri = vscode.Uri.joinPath(context.extensionUri, 'server', 'dist', 'paramlib-lsp.wasm');
    const wasmUrl = await vscode.env.asExternalUri(wasmUri);
    worker.postMessage({ type: '__paramlib_init__', wasmUrl: wasmUrl.toString() });

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

    await client.start();

    const sf = getEffectiveSchema();
    if (sf) await resolveAndSendSchema(sf, getEffectiveSchemaClass());

    client.sendRequest('$/paramlib/listSchemaClasses', {}).then(
        (classes) => { lastSchemaClasses = (classes as string[]) ?? []; },
    ).catch(() => { });

    context.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration(async e => {
            if (e.affectsConfiguration('paramlib.schemaFile') ||
                e.affectsConfiguration('paramlib.customSchemaPath') ||
                e.affectsConfiguration('paramlib.schemaClass')) {
                const updated = getEffectiveSchema();
                if (updated) await resolveAndSendSchema(updated, getEffectiveSchemaClass());
            }
        }),
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('paramlib.selectSchemaClass', pickSchemaClass),
    );
    context.subscriptions.push(client);
}

export function deactivate(): Thenable<void> | undefined {
    return client?.stop();
}
