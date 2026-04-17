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
    if (!wasm || !dispatchToClient) {
        return;
    }
    const slice = new Uint8Array(wasm.memory.buffer, ptr, len);
    dispatchToClient(slice.slice());
}

function sendToWasm(message: unknown): void {
    if (!wasm) { return; }
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

    let response: Response;
    try {
        response = await fetch(url);
    } catch (err) {
        console.error('[paramlib] fetch() threw — network error or URL blocked:', url, err);
        throw err;
    }


    if (!response.ok) {
        console.error('[paramlib] Bad HTTP response for WASM — check the URL above');
        throw new Error(`Failed to fetch WASM: ${response.status} ${response.statusText}`);
    }

    const bytes = await response.arrayBuffer();

    const { instance } = await WebAssembly.instantiate(bytes, {
        env: { clientSend },
    });
    wasm = instance.exports as unknown as ParamlibWasm;
}

const workerSelf = self as unknown as Worker;
const reader = new BrowserMessageReader(workerSelf);
const writer = new BrowserMessageWriter(workerSelf);

dispatchToClient = (data: Uint8Array): void => {
    const text = new TextDecoder().decode(data);
    const bodyStart = text.indexOf('\r\n\r\n');
    if (bodyStart === -1) { console.warn('[paramlib] dispatchToClient: no header separator'); return; }
    try {
        writer.write(JSON.parse(text.slice(bodyStart + 4)));
    } catch (e) { console.error('[paramlib] dispatchToClient parse error:', e, text.slice(0, 300)); }
};
const pendingMessages: unknown[] = [];

reader.listen((message) => {
    if (!wasm) {
        pendingMessages.push(message);
    } else {
        sendToWasm(message);
    }
});

loadWasm().then(() => {
    for (const msg of pendingMessages) sendToWasm(msg);
    pendingMessages.length = 0;
}).catch(console.error);