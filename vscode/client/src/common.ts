import * as vscode from 'vscode';
import { BaseLanguageClient as LanguageClient } from 'vscode-languageclient';

export async function pickSchemaFile(listBuiltinSchemas: () => Promise<string[]>): Promise<void> {
    const schemas = await listBuiltinSchemas();
    const items = [
        ...schemas.map(s => ({ label: s, description: 'Built-in', value: `builtin:${s}` })),
        { label: 'Custom…', description: 'Enter a path or URL', value: 'custom' }
    ];

    const picked = await vscode.window.showQuickPick(items, {
        title: 'ParamLib: Select Schema File',
        placeHolder: 'Choose a schema for completions',
    });

    if (!picked) return;

    const cfg = vscode.workspace.getConfiguration('paramlib');
    if (picked.value === 'custom') {
        const customPath = await vscode.window.showInputBox({
            title: 'ParamLib: Custom Schema Path',
            placeHolder: 'Enter absolute path or URL to .cpp/.json schema',
            value: cfg.get('customSchemaPath', ''),
        });
        if (customPath === undefined) return;
        await cfg.update('customSchemaPath', customPath, vscode.ConfigurationTarget.Workspace);
        await cfg.update('schemaFile', 'custom', vscode.ConfigurationTarget.Workspace);
    } else {
        await cfg.update('schemaFile', picked.value, vscode.ConfigurationTarget.Workspace);
    }
}

export async function pickSchemaClass(client: LanguageClient): Promise<void> {
    const uri = vscode.window.activeTextEditor?.document.uri;
    if (!uri) {
        void vscode.window.showErrorMessage('No active editor found.');
        return;
    }

    try {
        const classes = await client.sendRequest<string[]>('$/paramlib/listSchemaClasses', {
            textDocument: { uri: uri.toString() }
        });
        if (!classes || classes.length === 0) {
            void vscode.window.showInformationMessage('No schema classes available for this file.');
            return;
        }

        const picked = await vscode.window.showQuickPick(classes, {
            title: 'ParamLib: Select Schema Class',
            placeHolder: 'Choose a CfgSchemas class to activate',
        });
        if (picked === undefined) return;
        await vscode.workspace.getConfiguration('paramlib').update(
            'schemaClass', picked, vscode.ConfigurationTarget.Workspace,
        );
    } catch (e) {
        console.error('[paramlib] listSchemaClasses failed:', e);
    }
}

export async function logDebugInfo(client: LanguageClient): Promise<void> {
    try {
        await client.sendRequest('$/paramlib/ping');
    } catch { }
    const uri = vscode.window.activeTextEditor?.document.uri;
    if (uri) {
        try {
            const info = await client.sendRequest('$/paramlib/getDebugInfo', { uri: uri.toString() });
            console.log(`[ParamLib] Debug Info for ${uri.toString()}:`, info);
        } catch (e) {
            console.error('[ParamLib] Failed to get debug info:', e);
        }
    } else {
        console.warn('[ParamLib] No active editor found for doc info.');
    }
}

export function getEffectiveSchemaClass(): string | undefined {
    const cfg = vscode.workspace.getConfiguration('paramlib');
    const cls: string = cfg.get('schemaClass', '');
    return cls.length > 0 ? cls : undefined;
}

export function getEffectiveSchema(): string {
    const cfg = vscode.workspace.getConfiguration('paramlib');
    const schemaFile: string = cfg.get('schemaFile', 'builtin:dayz');
    if (schemaFile === 'custom') return cfg.get('customSchemaPath', '');
    return schemaFile;
}

export function registerConfigChangeListener(
    context: vscode.ExtensionContext,
    resolveAndSendSchema: (value: string, className?: string) => Promise<void>,
): void {
    context.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration(async e => {
            if (e.affectsConfiguration('paramlib.schemaFile') ||
                e.affectsConfiguration('paramlib.customSchemaPath') ||
                e.affectsConfiguration('paramlib.schemaClass')) {
                const updated = getEffectiveSchema();
                if (updated) {
                    if (updated !== 'builtin:dayz') {
                        await resolveAndSendSchema('builtin:dayz');
                    }
                    await resolveAndSendSchema(updated, getEffectiveSchemaClass());
                }
            }
        }),
    );
}

export async function ensureLocalSchema(docUri: vscode.Uri, client: LanguageClient, currentSchema: string | undefined, currentClass: string | undefined, resolveAndSendSchema: (value: string, className?: string, content?: string) => Promise<void>)  {
    if (docUri.scheme === 'untitled') return;
    if (docUri.path.endsWith('paramlib.cpp')) return;

    let currentDir = vscode.Uri.joinPath(docUri, '..');
    const workspaceFolder = vscode.workspace.getWorkspaceFolder(docUri);
    const workspaceRoot = workspaceFolder?.uri;

    const contents: string[] = [];
    const schemaUris: string[] = [];

    while (true) {
        const schemaUri = vscode.Uri.joinPath(currentDir, 'paramlib.cpp');
        try {
            const stat = await vscode.workspace.fs.stat(schemaUri);
            if (stat.type === vscode.FileType.File) {
                const bytes = await vscode.workspace.fs.readFile(schemaUri);
                contents.push(new TextDecoder().decode(bytes));
                schemaUris.push(schemaUri.toString());
            }
        } catch {  }

        if (workspaceRoot && currentDir.toString() === workspaceRoot.toString()) break;
        const parentDir = vscode.Uri.joinPath(currentDir, '..');
        if (parentDir.toString() === currentDir.toString()) break;
        currentDir = parentDir;
    }

    if (contents.length > 0) {
        const mergedContent = contents.reverse().join('\n');
        const mainSchemaUri = schemaUris[0];

        let cls = getEffectiveSchemaClass();
        if (!cls) {
            try {
                const classes = await client.sendRequest<string[]>('$/paramlib/listClassesInContent', {
                    content: mergedContent
                });
                if (classes && classes.length > 0) {
                    cls = classes[classes.length - 1];
                }
            } catch (e) {
                console.error('[paramlib] listClassesInContent failed in ensureLocalSchema:', e);
            }
        }

        if (currentSchema === mainSchemaUri && currentClass === cls) return;
        await resolveAndSendSchema(mainSchemaUri, cls, mergedContent);
        return;
    }

    const globalSchema = getEffectiveSchema();
    if (currentSchema !== globalSchema) {
        if (globalSchema !== 'builtin:dayz') {
            await resolveAndSendSchema('builtin:dayz');
        }
        await resolveAndSendSchema(globalSchema, getEffectiveSchemaClass());
    }
}