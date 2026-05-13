import * as fs   from 'fs';
import * as path from 'path';

import { ParamlibWasm, wasmSendFrame, wasmSendSchema } from './common';
import { ParserManager } from './parser';
import { mergeLspResults } from './lsp-merge';
import { buildCapabilitiesPatch } from './lsp-capabilities';

const LOG = fs.createWriteStream(
    path.join(require('os').tmpdir(), 'paramlib-lsp.log'),
    { flags: 'a' },
);
function log(...args: unknown[]): void {
    const line = `[${new Date().toISOString()}] ${args.map(a =>
        typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ')}\n`;
    LOG.write(line);
}

log('--- server start ---');

let wasm: ParamlibWasm;
const documentTexts = new Map<string, string>();
const pendingRequests = new Map<number | string, { method: string, params: any, uri?: string, wasmResults: string[] }>();
const nativeDiagCache = new Map<string, any[]>();

function emitMergedDiagnostics(uri: string, nativeDiags: any[]): void {
    const merged = parserManager.mergePublishDiagnostics(uri, nativeDiags);
    const body = JSON.stringify({
        jsonrpc: '2.0',
        method: 'textDocument/publishDiagnostics',
        params: { uri, diagnostics: merged },
    });
    log('emitMergedDiagnostics: uri=%s native=%d wasm=%d total=%d',
        uri, nativeDiags.length, merged.length - nativeDiags.length, merged.length);
    process.stdout.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
}

const parserManager = new ParserManager(
    (msg) => sendRpcToWasm({ jsonrpc: '2.0', ...msg }),
    (name) => path.join(__dirname, 'parsers', `${name}.wasm`),
    (uri, methods) => {
        log('sendRefresh uri=%s methods=%j', uri, methods);
        for (const method of methods) {
            const body = JSON.stringify({ jsonrpc: '2.0', method, params: null });
            process.stdout.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
        }
    },
    (p) => fs.readFileSync(p),
    (source) => {
        if (source.startsWith('http://') || source.startsWith('https://')) return source;
        return path.resolve(source);
    },
    (uri, _wasmDiags) => {

        const native = nativeDiagCache.get(uri);
        if (native !== undefined) emitMergedDiagnostics(uri, native);
    },
);

function clientSend(ptr: number, len: number): void {
    const slice = new Uint8Array(wasm.memory.buffer, ptr, len);
    const text = new TextDecoder().decode(slice);
    const bodyStart = text.indexOf('\r\n\r\n');
    if (bodyStart !== -1) {
        try {
            const bodyText = text.slice(bodyStart + 4);
            const msg = JSON.parse(bodyText);

            if (msg.result && msg.result.capabilities) {
                const patch = buildCapabilitiesPatch(parserManager.getRegisteredMethods());
                log('capabilities patch (at initialize, registeredMethods=%j): %j',
                    parserManager.getRegisteredMethods(), patch);
                Object.assign(msg.result.capabilities, patch);
                const newBody = JSON.stringify(msg);
                const header = `Content-Length: ${Buffer.byteLength(newBody)}\r\n\r\n`;
                process.stdout.write(header + newBody);
                return;
            }

            if (msg.method === 'textDocument/publishDiagnostics' && msg.params?.uri) {
                const uri = msg.params.uri as string;
                const native: any[] = msg.params.diagnostics ?? [];
                nativeDiagCache.set(uri, native);
                const merged = parserManager.mergePublishDiagnostics(uri, native);
                if (merged.length !== native.length) {
                    log('publishDiagnostics intercept: uri=%s native=%d merged=%d', uri, native.length, merged.length);
                    msg.params.diagnostics = merged;
                    const newBody = JSON.stringify(msg);
                    process.stdout.write(`Content-Length: ${Buffer.byteLength(newBody)}\r\n\r\n${newBody}`);
                    return;
                }
            }

            if (msg.id === 'schemaReset') {
                log('schemaReset response received (internal, suppressed)');
                return;
            }

            if (msg.id === 'getRules') {
                log('getRules response: %d rules', (msg.result || []).length);
                parserManager.updateRules(msg.result || []).then(() => {
                    const methods = parserManager.getRegisteredMethods();
                    log('updateRules done, registeredMethods=%j', methods);
                    const hasDiagnostic = methods.some(
                        m => m === 'textDocument_diagnostic' || m === 'diagnostic',
                    );
                    log('hasDiagnostic=%s', hasDiagnostic);
                    if (hasDiagnostic) {
                        const body = JSON.stringify({
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
                        log('sending client/registerCapability for textDocument/diagnostic');
                        process.stdout.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
                    }
                }).catch(e => log('updateRules error:', e));
                return;
            }
            if (typeof msg.id === 'string' && msg.id.startsWith('getParams:')) {
                const uri = msg.id.slice(10);
                parserManager.processDocument(uri, msg.result.params);
                return;
            }

            if (msg.id !== undefined && !msg.method) {
                const pending = pendingRequests.get(msg.id);
                if (pending) {
                    pendingRequests.delete(msg.id);
                    const before = msg.result;
                    msg.result = mergeLspResults(pending.method, msg.result, pending.wasmResults, pending.params);
                    if (pending.method === 'textDocument/diagnostic') {
                        log('diagnostic merge: base=%j wasmResults=%j -> merged=%j',
                            before, pending.wasmResults, msg.result);
                    }
                    if (msg.result !== undefined && msg.result !== null) {
                        delete msg.error;
                    }
                    const newBody = JSON.stringify(msg);
                    const header = `Content-Length: ${Buffer.byteLength(newBody)}\r\n\r\n`;
                    process.stdout.write(header + newBody);
                    return;
                }
            }
        } catch (e) { log('clientSend parse error:', e); }
    }
    process.stdout.write(Buffer.from(slice));
}

function sendToWasm(data: Buffer): void {
    wasmSendFrame(wasm, data);
}

function sendRpcToWasm(msg: object): void {
    const body   = JSON.stringify(msg);
    const header = `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n`;
    sendToWasm(Buffer.from(header + body));
}

async function main(): Promise<void> {
    const wasmPath = path.join(__dirname, 'paramlib-lsp.wasm');
    log('loading wasm from %s', wasmPath);
    const bytes = fs.readFileSync(wasmPath);
    const { instance } = await WebAssembly.instantiate(bytes, {
        env: {
            clientSend,
            wasm_log(ptr: number, len: number): void {
                const bytes = new Uint8Array(wasm.memory.buffer, ptr, len);
                const msg = new TextDecoder().decode(bytes);
                log('[WASM] %s', msg);
            }
        },
    });
    wasm = instance.exports as unknown as ParamlibWasm;
    log('wasm loaded');

    const schemaFile = process.env['PARAMLIB_SCHEMA_FILE'];
    log('PARAMLIB_SCHEMA_FILE=%s', schemaFile);

    // Auto-detect paramlib.cpp in the working directory when no explicit file is set.
    const autoSchemaPath = path.join(process.cwd(), 'paramlib.cpp');
    const resolvedSchemaFile: string | null =
        schemaFile
            ? schemaFile
            : fs.existsSync(autoSchemaPath)
                ? autoSchemaPath
                : null;
    log('resolvedSchemaFile=%s', resolvedSchemaFile);

    if (resolvedSchemaFile) {
        const sendSchema = (): void => {
            try {
                const bytes = fs.readFileSync(resolvedSchemaFile);
                wasmSendSchema(wasm, bytes);

                parserManager.reset();

                sendRpcToWasm({ jsonrpc: '2.0', id: 'schemaReset', method: '$/paramlib/resetSchema' });

                sendRpcToWasm({ jsonrpc: '2.0', id: 'getRules', method: '$/paramlib/getParserRules' });

                log('schema sent, reset + getRules requested (file=%s)', resolvedSchemaFile);
            } catch (e) {
                log('Failed to load schema file:', e);
                console.error('[paramlib] Failed to load schema file:', e);
            }
        };
        sendSchema();
        try {
            fs.watch(resolvedSchemaFile, () => { sendSchema(); });
        } catch (e) {
            console.error('[paramlib] fs.watch failed for schema file:', e);
        }
    }

    let buf = Buffer.alloc(0);

    process.stdin.on('data', (chunk: Buffer) => {
        buf = Buffer.concat([buf, chunk]);

        while (true) {
            const headerEnd = buf.indexOf('\r\n\r\n');
            if (headerEnd === -1) break;

            const header = buf.slice(0, headerEnd).toString('utf8');
            const match = header.match(/Content-Length:\s*(\d+)/i);
            if (!match) { buf = buf.slice(headerEnd + 4); break; }

            const bodyLen = parseInt(match[1], 10);
            const frameEnd = headerEnd + 4 + bodyLen;
            if (buf.length < frameEnd) break;

            const frame = buf.slice(0, frameEnd);

            try {
                const body = JSON.parse(buf.slice(headerEnd + 4, frameEnd).toString('utf8'));

                if (body.id !== undefined && body.method) {
                    const uri = body.params?.textDocument?.uri as string | undefined;
                    const wasmResults = parserManager.handleLsp(body.method, body.params, uri);
                    if (body.method === 'textDocument/diagnostic') {
                        log('textDocument/diagnostic request: uri=%s wasmResults=%j hints=%j',
                            uri,
                            wasmResults,
                            uri ? parserManager.getHints(uri) : []);
                    }
                    pendingRequests.set(body.id, {
                        method: body.method,
                        params: body.params,
                        uri,
                        wasmResults,
                    });
                }

                if (body.method === 'textDocument/didOpen') {
                    const uri  = body.params.textDocument.uri as string;
                    const text = body.params.textDocument.text as string;
                    log('didOpen uri=%s len=%d', uri, text.length);
                    documentTexts.set(uri, text);
                    parserManager.openDocument(uri, text);
                    void parserManager.processDocument(uri, [], text);
                } else if (body.method === 'textDocument/didChange') {
                    if (body.params.contentChanges.length > 0) {
                        const change = body.params.contentChanges[body.params.contentChanges.length - 1];
                        if (change.text != null) {
                            const uri  = body.params.textDocument.uri as string;
                            const text = change.text as string;
                            documentTexts.set(uri, text);
                            parserManager.openDocument(uri, text);
                            void parserManager.processDocument(uri, [], text);
                        }
                    }
                } else if (body.method === 'textDocument/didClose') {
                    const uri = body.params.textDocument.uri as string;
                    documentTexts.delete(uri);
                    parserManager.closeDocument(uri);
                } else if (body.method === '__paramlib_cap_reg__' || body.id === '__paramlib_cap_reg__') {
                    log('client/registerCapability ack received: %j', body);
                }

                sendToWasm(frame);

                if (body.method === 'textDocument/didOpen' || body.method === 'textDocument/didChange') {
                    const uri = body.params.textDocument.uri as string;
                    setTimeout(() => {
                        sendRpcToWasm({ jsonrpc: '2.0', id: `getParams:${uri}`, method: '$/paramlib/getDocumentParams', params: { textDocument: { uri } } });
                    }, 0);
                }
            } catch (e) {
                log('stdin parse error:', e);
                sendToWasm(frame);
            }

            buf = buf.slice(frameEnd);
        }
    });

    process.stdin.resume();
}

main().catch(e => { log('main error:', e); console.error(e); });
