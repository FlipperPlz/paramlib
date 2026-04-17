import {
    BrowserMessageReader,
    BrowserMessageWriter,
    createConnection,
    ProposedFeatures,
} from 'vscode-languageserver/browser';
import { ParamlibWasm, wasmSendFrame } from './common';

declare const __EXTENSION_URL__: string;

let wasm: ParamlibWasm | null = null;
let dispatchToClient: ((data: Uint8Array) => void) | null = null;

function clientSend(ptr: number, len: number): void {
    console.log('[paramlib] clientSend called, len:', len);
    if (!wasm || !dispatchToClient) {
        console.warn('[paramlib] clientSend: wasm or dispatchToClient not ready');
        return;
    }
    const slice = new Uint8Array(wasm.memory.buffer, ptr, len);
    dispatchToClient(slice.slice());
}

function sendToWasm(message: unknown): void {
    if (!wasm) { console.warn('[paramlib] sendToWasm: wasm not ready'); return; }
    console.log('[paramlib] sendToWasm:', JSON.stringify(message).slice(0, 200));
    const body   = JSON.stringify(message);
    const enc = new TextEncoder();
    const bodyBytes = enc.encode(body);
    const header = enc.encode(`Content-Length: ${bodyBytes.length}\r\n\r\n`);
    const frame  = new Uint8Array(header.length + bodyBytes.length);
    frame.set(header);
    frame.set(bodyBytes, header.length);

    wasmSendFrame(wasm, frame);
}

async function loadWasm(): Promise<void> {
    const url = __EXTENSION_URL__ +  'paramlib-lsp.wasm';
    console.log('[paramlib] Fetching WASM from:', url);

    let response: Response;
    try {
        response = await fetch(url);
    } catch (err) {
        console.error('[paramlib] fetch() threw — network error or URL blocked:', url, err);
        throw err;
    }

    console.log('[paramlib] fetch response status:', response.status, response.statusText, 'ok:', response.ok);

    if (!response.ok) {
        console.error('[paramlib] Bad HTTP response for WASM — check the URL above');
        throw new Error(`Failed to fetch WASM: ${response.status} ${response.statusText}`);
    }

    const bytes = await response.arrayBuffer();
    console.log('[paramlib] WASM bytes received:', bytes.byteLength);

    const { instance } = await WebAssembly.instantiate(bytes, {
        env: { clientSend },
    });
    wasm = instance.exports as unknown as ParamlibWasm;
    console.log('[paramlib] WASM instantiated successfully');
}

const workerSelf = self as unknown as Worker;
const reader = new BrowserMessageReader(workerSelf);
const writer = new BrowserMessageWriter(workerSelf);

dispatchToClient = (data: Uint8Array): void => {
    const text = new TextDecoder().decode(data);
    const bodyStart = text.indexOf('\r\n\r\n');
    if (bodyStart === -1) { console.warn('[paramlib] dispatchToClient: no header separator'); return; }
    try {
        const msg = JSON.parse(text.slice(bodyStart + 4));
        console.log('[paramlib] dispatchToClient writing:', JSON.stringify(msg).slice(0, 200));
        writer.write(msg);
    } catch (e) { console.error('[paramlib] dispatchToClient parse error:', e, text.slice(0, 300)); }
};
const pendingMessages: unknown[] = [];

reader.listen((message) => {
    if (!wasm) {
        console.log('[paramlib] WASM not ready, queuing message');
        pendingMessages.push(message);
    } else {
        sendToWasm(message);
    }
});

loadWasm().then(() => {
    console.log('[paramlib] Draining', pendingMessages.length, 'queued messages');
    for (const msg of pendingMessages) sendToWasm(msg);
    pendingMessages.length = 0;
}).catch(console.error);