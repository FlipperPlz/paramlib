import * as fs from 'fs';
import * as path from 'path';
import {fileURLToPath} from 'url';
import * as vscode from 'vscode';
import {LanguageClient, LanguageClientOptions, ServerOptions, TransportKind,} from 'vscode-languageclient/node';
import {
    getEffectiveSchema,
    getEffectiveSchemaClass,
    logDebugInfo as logDebugInfoCommon,
    pickSchemaClass as pickSchemaClassCommon,
    pickSchemaFile as pickSchemaFileCommon,
    registerConfigChangeListener,
    ensureLocalSchema
} from './common';

let client: LanguageClient;
let ctx: vscode.ExtensionContext;

let currentSchema: string | undefined;
let currentClass: string | undefined;

async function listBuiltinSchemas(): Promise<string[]> {
    const schemasUri = vscode.Uri.file(ctx.asAbsolutePath('schemas'));
    try {
        const entries = await vscode.workspace.fs.readDirectory(schemasUri);
        return entries
            .filter(([n, t]) => t === vscode.FileType.File && n.endsWith('.cpp'))
            .map(([n]) => n.slice(0, -4));
    } catch (e) {
        console.error('[paramlib] listBuiltinSchemas: failed to read schemas dir', e);
        return [];
    }
}

async function resolveAndSendSchema(value: string, className?: string, content?: string): Promise<void> {
    if (content === undefined && value === currentSchema && className === currentClass) return;
    try {
        let text: string;
        if (content !== undefined) {
            text = content;
        } else if (value.startsWith('builtin:')) {
            const name = value.slice(8);
            const resolved = ctx.asAbsolutePath(path.join('schemas', `${name}.cpp`));
            text = fs.readFileSync(resolved, 'utf8');
        } else {
            const resolved = value.includes('://') ? fileURLToPath(value) : value;
            text = fs.readFileSync(resolved, 'utf8');
        }
        const schemaUri = value.startsWith('builtin:')
            ? vscode.Uri.file(ctx.asAbsolutePath(path.join('schemas', `${value.slice(8)}.cpp`))).toString()
            : (value.includes('://') ? vscode.Uri.parse(value).toString() : vscode.Uri.file(value).toString());
        currentSchema = value;
        currentClass = className;
        void client.sendNotification('$/paramlib/schemaUpdate', { uri: schemaUri, content: text, className });
    } catch (e) {
        console.error('[paramlib] resolveAndSendSchema failed:', e);
    }
}

export function activate(context: vscode.ExtensionContext): void {
    ctx = context;

    const debugObj = {
        printSchema: () => {
            console.log('[ParamLib] Current Schema:', currentSchema);
            console.log('[ParamLib] Current Class:', currentClass);
        },
        printDocInfo: async () => {
            const uri = vscode.window.activeTextEditor?.document.uri;
            if (!uri) {
                console.warn('[ParamLib] No active editor found.');
                return;
            }
            try {
                const info = await client.sendRequest('$/paramlib/getDebugInfo', { uri: uri.toString() });
                console.log(`[ParamLib] Debug Info for ${uri.toString()}:`, info);
            } catch (e) {
                console.error('[ParamLib] Failed to get debug info:', e);
            }
        }
    };
    Object.defineProperty(globalThis, 'paramlib', { value: debugObj, enumerable: true, configurable: true, writable: true });
    console.info('[ParamLib] Debug commands available on `paramlib` object.');

    void listBuiltinSchemas();

    const serverModule = context.asAbsolutePath(
        path.join('server', 'dist', 'serverNode.js'),
    );

    const effectiveSchema = getEffectiveSchema();
    const resolvedSchemaPath = effectiveSchema.startsWith('builtin:')
        ? context.asAbsolutePath(path.join('schemas', `${effectiveSchema.slice(8)}.cpp`))
        : effectiveSchema;

    const serverOptions: ServerOptions = {
        run: {
            module: serverModule,
            transport: TransportKind.stdio,
            options: { env: { ...process.env, ...(resolvedSchemaPath ? { PARAMLIB_SCHEMA_FILE: resolvedSchemaPath } : {}) } },
        },
        debug: {
            module: serverModule,
            transport: TransportKind.stdio,
            options: {
                execArgv: ['--nolazy', '--inspect=6009'],
                env: { ...process.env, ...(resolvedSchemaPath ? { PARAMLIB_SCHEMA_FILE: resolvedSchemaPath } : {}) },
            },
        },
    };

    const clientOptions: LanguageClientOptions = {
        documentSelector: [
            { language: 'paramlib' },
            { pattern: '**/config.cpp' },
            { pattern: '**/paramlib.cpp' },
            { pattern: '**/*.rvmat' },
        ],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.cpp'),
        },
    };

    client = new LanguageClient(
        'paramlib-lsp',
        'ParamLib Language Server',
        serverOptions,
        clientOptions,
    );

    void client.start().then(async () => {
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

        context.subscriptions.push(
            vscode.workspace.onDidChangeTextDocument(async e => {
                if (e.document.uri.path.endsWith('paramlib.cpp')) {
                    await resolveAndSendSchema(e.document.uri.toString(), getEffectiveSchemaClass(), e.document.getText());
                }

                const effective = getEffectiveSchema();
                const vUri = effective.startsWith('builtin:')
                    ? vscode.Uri.file(ctx.asAbsolutePath(path.join('schemas', `${effective.slice(8)}.cpp`)))
                    : (effective.includes('://') ? vscode.Uri.parse(effective) : vscode.Uri.file(effective));
                const schemaUri = vUri.toString();
                
                if (e.document.uri.toString() === schemaUri) {
                    await resolveAndSendSchema(effective, getEffectiveSchemaClass(), e.document.getText());
                }
            })
        );

        registerConfigChangeListener(context, resolveAndSendSchema);
    });

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
            void vscode.window.showInformationMessage('Debug info logged to console.');
        })
    );
    context.subscriptions.push(client);
}

export function deactivate(): Thenable<void> | undefined {
    return client?.stop();
}
