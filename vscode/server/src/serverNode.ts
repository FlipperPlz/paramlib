import * as fs   from 'fs';
import * as path from 'path';

import { ParamlibWasm, wasmSendFrame, wasmSendSchema } from './common';
import { ParserManager } from './parser';
import { mergeLspResults } from './lsp-merge';
import { buildCapabilitiesPatch } from './lsp-capabilities';

let wasm: ParamlibWasm;
const documentTexts = new Map<string, string>();
const pendingRequests = new Map<number | string, { method: string, params: any, uri?: string, wasmResults: string[] }>();

const parserManager = new ParserManager(
    (msg) => sendRpcToWasm({ jsonrpc: '2.0', ...msg }),
    (name) => path.join(__dirname, 'parsers', `${name}.wasm`),
    (uri, methods) => {
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
                Object.assign(msg.result.capabilities, patch);
                const newBody = JSON.stringify(msg);
                const header = `Content-Length: ${Buffer.byteLength(newBody)}\r\n\r\n`;
                process.stdout.write(header + newBody);
                return;
            }

            if (msg.id === 'getRules') {
                parserManager.updateRules(msg.result || []);
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
                    msg.result = mergeLspResults(pending.method, msg.result, pending.wasmResults);
                    if (msg.result !== undefined && msg.result !== null) {
                        delete msg.error;
                    }
                    const newBody = JSON.stringify(msg);
                    const header = `Content-Length: ${Buffer.byteLength(newBody)}\r\n\r\n`;
                    process.stdout.write(header + newBody);
                    return;
                }
            }
        } catch (e) {}
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
    const bytes = fs.readFileSync(wasmPath);
    const { instance } = await WebAssembly.instantiate(bytes, {
        env: { clientSend },
    });
    wasm = instance.exports as unknown as ParamlibWasm;

    const schemaFile = process.env['PARAMLIB_SCHEMA_FILE'];
    if (schemaFile) {
        const sendSchema = (): void => {
            try {
                const bytes = fs.readFileSync(schemaFile);
                wasmSendSchema(wasm, bytes);
                sendRpcToWasm({ jsonrpc: '2.0', id: 'getRules', method: '$/paramlib/getParserRules' });
            } catch (e) {
                console.error('[paramlib] Failed to load schema file:', e);
            }
        };
        sendSchema();
        try {
            fs.watch(schemaFile, () => { sendSchema(); });
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

                    pendingRequests.set(body.id, {
                        method: body.method,
                        params: body.params,
                        uri,
                        wasmResults
                    });
                }

                if (body.method === 'textDocument/didOpen') {
                    const uri  = body.params.textDocument.uri as string;
                    const text = body.params.textDocument.text as string;
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
                }

                sendToWasm(frame);

                if (body.method === 'textDocument/didOpen' || body.method === 'textDocument/didChange') {
                    const uri = body.params.textDocument.uri as string;
                    setTimeout(() => {
                        sendRpcToWasm({ jsonrpc: '2.0', id: `getParams:${uri}`, method: '$/paramlib/getDocumentParams', params: { textDocument: { uri } } });
                    }, 0);
                }
            } catch (e) {
                sendToWasm(frame);
            }

            buf = buf.slice(frameEnd);
        }
    });

    process.stdin.resume();
}

main().catch(console.error);
