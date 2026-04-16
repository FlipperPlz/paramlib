import * as fs   from 'fs';
import * as path from 'path';
import {
    createConnection,
    ProposedFeatures,
    StreamMessageReader,
    StreamMessageWriter,
} from 'vscode-languageserver/node';

import { ParamlibWasm, wasmSendFrame } from './common';

let wasm: ParamlibWasm;

function clientSend(ptr: number, len: number): void {
    const slice = new Uint8Array(wasm.memory.buffer, ptr, len);
    process.stdout.write(slice);
}

function sendToWasm(message: unknown): void {
    const body = JSON.stringify(message);
    const bodyBytes = Buffer.from(body, 'utf8');
    const header = Buffer.from(`Content-Length: ${bodyBytes.length}\r\n\r\n`, 'utf8');
    const frame = Buffer.concat([header, bodyBytes]);

    wasmSendFrame(wasm, frame);
}

async function main(): Promise<void> {
    const wasmPath = path.join(__dirname, 'paramlib-lsp.wasm');
    const bytes = fs.readFileSync(wasmPath);
    const { instance } = await WebAssembly.instantiate(bytes, {
        env: { clientSend },
    });
    wasm = instance.exports as unknown as ParamlibWasm;
    wasm.wasmInit();

    const reader = new StreamMessageReader(process.stdin);
    const writer = new StreamMessageWriter(process.stdout);
    const connection = createConnection(ProposedFeatures.all, reader, writer);

    reader.listen((message) => sendToWasm(message));
    connection.listen();
}

main().catch(console.error);
