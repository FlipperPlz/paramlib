import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
} from 'vscode-languageclient/browser';
import {
    pickSchemaFile as pickSchemaFileCommon,
    pickSchemaClass as pickSchemaClassCommon,
    logDebugInfo as logDebugInfoCommon,
    getEffectiveSchema,
    getEffectiveSchemaClass,
    registerConfigChangeListener,
    ensureLocalSchema
} from './common';

declare const __DEV_MODE__: boolean;
declare const __SCHEMAS_URL__: string;

let client: LanguageClient;
let ctx: vscode.ExtensionContext;

let currentSchema: string | undefined;
let currentClass: string | undefined;


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

async function resolveAndSendSchema(value: string, className?: string, content?: string): Promise<void> {
    if (content === undefined && value === currentSchema && className === currentClass) return;
    try {
        let text: string;
        let uri: string;
        if (value.startsWith('builtin:')) {
            const name = value.slice(8);
            const vUri = vscode.Uri.joinPath(ctx.extensionUri, 'schemas', `${name}.cpp`);
            uri = vUri.toString();
            if (content !== undefined) {
                text = content;
            } else if (__DEV_MODE__) {
                text = new TextDecoder().decode(await vscode.workspace.fs.readFile(vUri));
            } else {
                try {
                    text = new TextDecoder().decode(await vscode.workspace.fs.readFile(vUri));
                } catch {
                    const res = await fetch(`${__SCHEMAS_URL__}${name}.cpp`);
                    if (!res.ok) throw new Error(`CDN fetch failed: HTTP ${res.status}`);
                    text = await res.text();
                }
            }
        } else if (value.startsWith('http://') || value.startsWith('https://')) {
            uri = value;
            if (content !== undefined) {
                text = content;
            } else {
                const res = await fetch(value);
                if (!res.ok) throw new Error(`HTTP ${res.status}`);
                text = await res.text();
            }
        } else {
            const vUri = value.includes('://') ? vscode.Uri.parse(value) : vscode.Uri.file(value);
            uri = vUri.toString();
            if (content !== undefined) {
                text = content;
            } else {
                text = new TextDecoder().decode(
                    await vscode.workspace.fs.readFile(vUri),
                );
            }
        }
        currentSchema = value;
        currentClass = className;
        void client.sendNotification('$/paramlib/schemaUpdate', { uri, content: text, className });
    } catch (e) { console.error('[paramlib] resolveAndSendSchema failed:', e); }
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
            { pattern: '**/paramlib.cpp' },
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
    if (sf) {
        if (sf !== 'builtin:dayz') {
            await resolveAndSendSchema('builtin:dayz');
        }
        await resolveAndSendSchema(sf, getEffectiveSchemaClass());
    }

    if (vscode.window.activeTextEditor) {
        await ensureLocalSchema(vscode.window.activeTextEditor.document.uri, client, currentSchema, currentClass, resolveAndSendSchema);
    }

    context.subscriptions.push(
        vscode.window.onDidChangeActiveTextEditor(async editor => {
            if (editor) await ensureLocalSchema(editor.document.uri, client, currentSchema, currentClass, resolveAndSendSchema);
        }),
    );

    context.subscriptions.push(
        vscode.workspace.onDidOpenTextDocument(async doc => {
            await ensureLocalSchema(doc.uri, client, currentSchema, currentClass, resolveAndSendSchema);
        }),
    );

    registerConfigChangeListener(context, resolveAndSendSchema);

    context.subscriptions.push(
        vscode.workspace.onDidChangeTextDocument(async e => {
            if (e.document.uri.path.endsWith('paramlib.cpp')) {
                await resolveAndSendSchema(e.document.uri.toString(), getEffectiveSchemaClass(), e.document.getText());
            }

            const effective = getEffectiveSchema();
            const vUri = effective.startsWith('builtin:')
                ? vscode.Uri.joinPath(ctx.extensionUri, 'schemas', `${effective.slice(8)}.cpp`)
                : (effective.includes('://') ? vscode.Uri.parse(effective) : vscode.Uri.file(effective));
            const schemaUri = vUri.toString();
            
            if (e.document.uri.toString() === schemaUri) {
                await resolveAndSendSchema(effective, getEffectiveSchemaClass(), e.document.getText());
            }
        })
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('paramlib.selectSchemaFile', () => pickSchemaFileCommon(listBuiltinSchemas)),
    );
    context.subscriptions.push(
        vscode.commands.registerCommand('paramlib.selectSchemaClass', () => pickSchemaClassCommon(client)),
    );
    context.subscriptions.push(
        vscode.commands.registerCommand('paramlib.debugInfo', async () => {
            console.log('[ParamLib] Current Schema:', currentSchema);
            console.log('[ParamLib] Current Class:', currentClass);
            await logDebugInfoCommon(client);
            void vscode.window.showInformationMessage('Debug info logged to console. (Ensure console context is "Extension Host")');
        })
    );
    context.subscriptions.push(client);
}

export function deactivate(): Thenable<void> | undefined {
    return client?.stop();
}
