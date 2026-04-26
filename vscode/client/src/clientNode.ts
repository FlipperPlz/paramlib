import * as fs   from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind,
} from 'vscode-languageclient/node';

let client: LanguageClient;
let ctx: vscode.ExtensionContext;

async function listBuiltinSchemas(): Promise<string[]> {
    const schemasUri = vscode.Uri.file(ctx.asAbsolutePath('schemas'));
    console.log('[paramlib] listBuiltinSchemas: scanning', schemasUri.fsPath);
    try {
        const entries = await vscode.workspace.fs.readDirectory(schemasUri);
        const schemas = entries
            .filter(([n, t]) => t === vscode.FileType.File && n.endsWith('.cpp'))
            .map(([n]) => n.slice(0, -4));
        console.log('[paramlib] listBuiltinSchemas: found', schemas);
        return schemas;
    } catch (e) {
        console.error('[paramlib] listBuiltinSchemas: failed to read schemas dir', e);
        return [];
    }
}

async function resolveAndSendSchema(value: string): Promise<void> {
    console.log('[paramlib] resolveAndSendSchema: value =', value);
    try {
        let text: string;
        if (value.startsWith('builtin:')) {
            const name = value.slice(8);
            const resolved = ctx.asAbsolutePath(path.join('schemas', `${name}.cpp`));
            console.log('[paramlib] resolveAndSendSchema: resolved builtin path =', resolved);
            text = fs.readFileSync(resolved, 'utf8');
        } else {
            console.log('[paramlib] resolveAndSendSchema: reading custom path =', value);
            text = fs.readFileSync(value, 'utf8');
        }
        console.log('[paramlib] resolveAndSendSchema: sending schema, length =', text.length);
        void client.sendNotification('$/paramlib/schemaUpdate', { content: text });
        console.log('[paramlib] resolveAndSendSchema: notification sent');
    } catch (e) {
        console.error('[paramlib] resolveAndSendSchema failed:', e);
    }
}

function getEffectiveSchema(): string {
    const cfg = vscode.workspace.getConfiguration('paramlib');
    const schemaFile: string = cfg.get('schemaFile', 'builtin:dayz');
    if (schemaFile === 'custom') return cfg.get('customSchemaPath', '');
    return schemaFile;
}

export function activate(context: vscode.ExtensionContext): void {
    ctx = context;

    console.log('[paramlib] extensionUri:', context.extensionUri.fsPath);
    console.log('[paramlib] schemas path:', context.asAbsolutePath('schemas'));

    void listBuiltinSchemas();

    const serverModule = context.asAbsolutePath(
        path.join('server', 'dist', 'serverNode.js'),
    );

    const effectiveSchema = getEffectiveSchema();
    const resolvedSchemaPath = effectiveSchema.startsWith('builtin:')
        ? context.asAbsolutePath(path.join('schemas', `${effectiveSchema.slice(8)}.cpp`))
        : effectiveSchema;
    console.log('[paramlib] effectiveSchema:', effectiveSchema);
    console.log('[paramlib] resolvedSchemaPath:', resolvedSchemaPath);

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
        console.log('[paramlib] client started');
        const sf = getEffectiveSchema();
        if (sf) {
            console.log('[paramlib] sending initial schema:', sf);
            await resolveAndSendSchema(sf);
        }

        context.subscriptions.push(
            vscode.workspace.onDidChangeConfiguration(async e => {
                if (e.affectsConfiguration('paramlib.schemaFile') ||
                    e.affectsConfiguration('paramlib.customSchemaPath')) {
                    const updated = getEffectiveSchema();
                    console.log('[paramlib] config changed, new schema:', updated);
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
