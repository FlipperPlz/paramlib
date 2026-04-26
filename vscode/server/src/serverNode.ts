import * as fs   from 'fs';
import * as path from 'path';

import { ParamlibWasm, wasmSendFrame, wasmSendSchema } from './common';

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

    const schemaFile = process.env['PARAMLIB_SCHEMA_FILE'];
    console.error('[paramlib] PARAMLIB_SCHEMA_FILE:', schemaFile ?? '(not set)');
    if (schemaFile) {
        const sendSchema = (): void => {
            try {
                console.error('[paramlib] loading schema from:', schemaFile);
                const bytes = fs.readFileSync(schemaFile);
                console.error('[paramlib] schema loaded, bytes:', bytes.length);
                wasmSendSchema(wasm, bytes);
                console.error('[paramlib] schema sent to wasm');
            } catch (e) {
                console.error('[paramlib] Failed to load schema file:', e);
            }
        };
        sendSchema();
        try {
            fs.watch(schemaFile, () => {
                console.error('[paramlib] schema file changed, reloading:', schemaFile);
                sendSchema();
            });
            console.error('[paramlib] watching schema file for changes:', schemaFile);
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
            sendToWasm(frame);
            buf = buf.slice(frameEnd);
        }
    });

    process.stdin.resume();
}

main().catch(console.error);
