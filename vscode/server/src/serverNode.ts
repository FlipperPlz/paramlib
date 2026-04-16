import * as fs   from 'fs';
import * as path from 'path';

import { ParamlibWasm, wasmSendFrame } from './common';

let wasm: ParamlibWasm;

function clientSend(ptr: number, len: number): void {
    const slice = new Uint8Array(wasm.memory.buffer, ptr, len);
    process.stdout.write(slice);
}

function sendToWasm(data: Buffer): void {
    wasmSendFrame(wasm, data);
}

async function main(): Promise<void> {
    const wasmPath = path.join(__dirname, 'paramlib-lsp.wasm');
    const bytes = fs.readFileSync(wasmPath);
    const { instance } = await WebAssembly.instantiate(bytes, {
        env: { clientSend },
    });
    wasm = instance.exports as unknown as ParamlibWasm;

    // Read raw LSP frames from stdin and forward directly to WASM.
    // We intentionally bypass vscode-languageserver's connection here because
    // the WASM module speaks LSP natively — it handles framing itself.
    let buf = Buffer.alloc(0);

    process.stdin.on('data', (chunk: Buffer) => {
        buf = Buffer.concat([buf, chunk]);

        // Consume all complete LSP frames in the buffer
        while (true) {
            const headerEnd = buf.indexOf('\r\n\r\n');
            if (headerEnd === -1) break;

            const header = buf.slice(0, headerEnd).toString('utf8');
            const match = header.match(/Content-Length:\s*(\d+)/i);
            if (!match) { buf = buf.slice(headerEnd + 4); break; }

            const bodyLen = parseInt(match[1], 10);
            const frameEnd = headerEnd + 4 + bodyLen;
            if (buf.length < frameEnd) break; // wait for more data

            const frame = buf.slice(0, frameEnd);
            sendToWasm(frame);
            buf = buf.slice(frameEnd);
        }
    });

    process.stdin.resume();
}

main().catch(console.error);
