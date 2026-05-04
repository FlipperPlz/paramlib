import {
    BrowserMessageReader,
    BrowserMessageWriter
} from 'vscode-languageserver/browser';
import { ParamlibWasm, wasmSendFrame, wasmSendSchema } from './common';
import { ParserManager } from './parser';
import { mergeLspResults } from './lsp-merge';
import { buildCapabilitiesPatch } from './lsp-capabilities';

declare const __EXTENSION_URL__: string | undefined;

let wasm: ParamlibWasm | null = null;
let dispatchToClient: ((data: Uint8Array) => void) | null = null;
let resolveWasmUrl: (url: string) => void;
const wasmUrlPromise = new Promise<string>(res => { resolveWasmUrl = res; });

let serverDistBase: string = (typeof __EXTENSION_URL__ === 'string' && __EXTENSION_URL__)
    ? (__EXTENSION_URL__.endsWith('/') ? __EXTENSION_URL__ : __EXTENSION_URL__ + '/')
    : '';

if (typeof __EXTENSION_URL__ === 'string' && __EXTENSION_URL__) {
    resolveWasmUrl!(__EXTENSION_URL__ + 'paramlib-lsp.wasm');
}

const parserManager = new ParserManager(
    (msg) => sendToWasm(msg),
    (name) => `${serverDistBase}parsers/${name}.wasm`,
    (_uri, methods) => {
        for (const method of methods) {
            // @ts-ignore
            writer.write({ jsonrpc: "2.0", method, params: null });
        }
    },
    undefined,
    (source) => {
        if (source.startsWith('http://') || source.startsWith('https://')) return source;
        return `${serverDistBase}${source}`;
    },
    (uri, _wasmDiags) => {
        const native = nativeDiagCache.get(uri);
        if (native !== undefined) emitMergedDiagnostics(uri, native);
    },
);

function clientSend(ptr: number, len: number): void {
    if (!wasm || !dispatchToClient) return;
    dispatchToClient(new Uint8Array(wasm.memory.buffer, ptr, len).slice());
}

function sendToWasm(message: unknown): void {
    if (!wasm) return;
    const enc       = new TextEncoder();
    const bodyBytes = enc.encode(JSON.stringify(message));
    const header    = enc.encode(`Content-Length: ${bodyBytes.length}\r\n\r\n`);
    const frame     = new Uint8Array(header.length + bodyBytes.length);
    frame.set(header);
    frame.set(bodyBytes, header.length);
    wasmSendFrame(wasm, frame);
}

async function loadWasm(): Promise<void> {
    const url = await wasmUrlPromise;
    let response: Response;
    try {
        response = await fetch(url);
    } catch (err) {
        console.error('[parser-wasm] fetch failed:', url, err);
        throw err;
    }
    if (!response.ok) {
        console.error('[parser-wasm] bad HTTP response for WASM:', url, response.status);
        throw new Error(`Failed to fetch WASM: ${response.status}`);
    }
    const { instance } = await WebAssembly.instantiate(await response.arrayBuffer(), {
        env: { clientSend },
    });
    wasm = instance.exports as unknown as ParamlibWasm;
}

const workerSelf = self as unknown as Worker;
const reader = new BrowserMessageReader(workerSelf);
const writer = new BrowserMessageWriter(workerSelf);

workerSelf.addEventListener('message', (e: MessageEvent) => {
    if (e.data?.type === '__paramlib_init__' && typeof e.data.wasmUrl === 'string') {
        const wasmUrl: string = e.data.wasmUrl;
        resolveWasmUrl(wasmUrl);
        if (!serverDistBase) {
            serverDistBase = wasmUrl.substring(0, wasmUrl.lastIndexOf('/') + 1);
        }
    }
}, { once: true });

const documentTexts = new Map<string, string>();
const pendingRequests = new Map<number | string, { method: string, params: any, uri?: string, wasmResults: string[] }>();
const nativeDiagCache = new Map<string, any[]>();

function emitMergedDiagnostics(uri: string, nativeDiags: any[]): void {
    const merged = parserManager.mergePublishDiagnostics(uri, nativeDiags);
    // @ts-ignore
    writer.write({
        jsonrpc: '2.0',
        method: 'textDocument/publishDiagnostics',
        params: { uri, diagnostics: merged },
    });
}

dispatchToClient = (data: Uint8Array): void => {
    const text      = new TextDecoder().decode(data);
    const bodyStart = text.indexOf('\r\n\r\n');
    if (bodyStart === -1) return;
    try {
        const msg = JSON.parse(text.slice(bodyStart + 4));

        if (msg.result?.capabilities) {
            const patch = buildCapabilitiesPatch(parserManager.getRegisteredMethods());
            Object.assign(msg.result.capabilities, patch);
            writer.write(msg);
            return;
        }

        if (msg.method === 'textDocument/publishDiagnostics' && msg.params?.uri) {
            const uri = msg.params.uri as string;
            const native: any[] = msg.params.diagnostics ?? [];
            nativeDiagCache.set(uri, native);
            const merged = parserManager.mergePublishDiagnostics(uri, native);
            msg.params.diagnostics = merged;
            writer.write(msg);
            return;
        }

        if (msg.id === 'getRules') {
            parserManager.updateRules(msg.result || []).then(() => {
                const methods = parserManager.getRegisteredMethods();
                const hasDiagnostic = methods.some(
                    m => m === 'textDocument_diagnostic' || m === 'diagnostic',
                );
                if (hasDiagnostic) {
                    // @ts-ignore
                    writer.write({
                        jsonrpc: '2.0',
                        id: '__paramlib_cap_reg__',
                        method: 'client/registerCapability',
                        params: {
                            registrations: [{
                                id: 'paramlib-diagnosticProvider',
                                method: 'textDocument/diagnostic',
                                registerOptions: {
                                    interFileDependencies: false,
                                    workspaceDiagnostics:  false,
                                },
                            }],
                        },
                    });
                }
            }).catch(console.error);
            return;
        }

        if (typeof msg.id === 'string' && msg.id.startsWith('getParams:')) {
            const uri = msg.id.slice('getParams:'.length);
            parserManager.processDocument(uri, msg.result?.params ?? []);
            return;
        }

        if (msg.id !== undefined && !msg.method) {
            const pending = pendingRequests.get(msg.id);
            if (pending) {
                pendingRequests.delete(msg.id);
                msg.result = mergeLspResults(pending.method, msg.result, pending.wasmResults, pending.params);
                if (msg.result !== undefined && msg.result !== null) {
                    delete msg.error;
                }
            }
        }
        writer.write(msg);
    } catch (e) { console.error('[parser-wasm] dispatch error:', e); }
};

let pendingSchema: { content: Uint8Array, className?: string } | null = null;
const pendingMessages: unknown[] = [];

reader.listen((message) => {
    if ((message as any).type === '__paramlib_init__') return;

    const m = message as { method?: string; params?: any; id?: any };

    if (!m.method && m.id === undefined) return; 

    if (m.id !== undefined && m.method) {
        const uri        = m.params?.textDocument?.uri as string | undefined;
        const wasmResults = parserManager.handleLsp(m.method, m.params, uri);

        pendingRequests.set(m.id, { method: m.method, params: m.params, uri, wasmResults });
    }

    if (m.method === '$/paramlib/schemaUpdate' && m.params?.content != null) {
        const className = (m.params as { content: string; className?: string }).className;
        const encoded   = new TextEncoder().encode(m.params.content);
        if (wasm) {
            wasmSendSchema(wasm, encoded, className);
            sendToWasm({ jsonrpc: '2.0', id: 'getRules', method: '$/paramlib/getParserRules' });
        } else {
            pendingSchema = { content: encoded, className };
        }
        return;
    }

    if (m.method === 'textDocument/didOpen') {
        const { uri, text } = m.params.textDocument;
        documentTexts.set(uri, text);
        parserManager.openDocument(uri, text);
        void parserManager.processDocument(uri, [], text);
    } else if (m.method === 'textDocument/didChange') {
        const change = m.params.contentChanges?.at(-1);
        if (change?.text != null) {
            const uri = m.params.textDocument.uri;
            documentTexts.set(uri, change.text);
            parserManager.openDocument(uri, change.text);
            void parserManager.processDocument(uri, [], change.text);
        }
    } else if (m.method === 'textDocument/didClose') {
        const uri = m.params.textDocument.uri;
        documentTexts.delete(uri);
        parserManager.closeDocument(uri);
    }

    if (!wasm) {
        pendingMessages.push(message);
    } else {
        sendToWasm(message);
        if (m.method === 'textDocument/didOpen' || m.method === 'textDocument/didChange') {
            const uri = m.params.textDocument.uri;
            setTimeout(() => {
                sendToWasm({ jsonrpc: '2.0', id: `getParams:${uri}`, method: '$/paramlib/getDocumentParams', params: { textDocument: { uri } } });
            }, 0);
        }
    }
});

loadWasm().then(() => {
    for (const msg of pendingMessages) sendToWasm(msg);
    pendingMessages.length = 0;
    if (pendingSchema) {
        wasmSendSchema(wasm!, pendingSchema.content, pendingSchema.className);
        pendingSchema = null;
    }
    sendToWasm({ jsonrpc: '2.0', id: 'getRules', method: '$/paramlib/getParserRules' });
}).catch(console.error);
