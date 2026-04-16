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
    if (!wasm || !dispatchToClient) return;
    const slice = new Uint8Array(wasm.memory.buffer, ptr, len);
    dispatchToClient(slice.slice());
}

async function loadWasm(): Promise<void> {
    const url = __EXTENSION_URL__ + 'paramlib-lsp.wasm';
    const response = await fetch(url);
    const bytes = await response.arrayBuffer();
    const { instance } = await WebAssembly.instantiate(bytes, {
        env: { clientSend },
    });
    wasm = instance.exports as unknown as ParamlibWasm;
}

function sendToWasm(message: unknown): void {
    if (!wasm) return;
    const body   = JSON.stringify(message);
    const enc = new TextEncoder();
    const bodyBytes = enc.encode(body);
    const header = enc.encode(`Content-Length: ${bodyBytes.length}\r\n\r\n`);
    const frame  = new Uint8Array(header.length + bodyBytes.length);
    frame.set(header);
    frame.set(bodyBytes, header.length);

    wasmSendFrame(wasm, frame);
}

const workerSelf = self as unknown as Worker;
const reader = new BrowserMessageReader(workerSelf);
const writer = new BrowserMessageWriter(workerSelf);

dispatchToClient = (data: Uint8Array): void => {
    const text = new TextDecoder().decode(data);
    const bodyStart = text.indexOf('\r\n\r\n');
    if (bodyStart === -1) return;
    try {
        const msg = JSON.parse(text.slice(bodyStart + 4));
        writer.write(msg);
    } catch { }
};

loadWasm().then(() => {
    reader.listen((message) => sendToWasm(message));
    const connection = createConnection(ProposedFeatures.all, reader, writer);
    connection.listen();
}).catch(console.error);
