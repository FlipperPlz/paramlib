export interface ParamlibWasm {
    memory:      WebAssembly.Memory;
    serverSend(ptr: number, len: number): void;
    alloc(len: number): number;
    free(ptr: number, len: number): void;
    schemaUpdate(contentPtr: number, contentLen: number, classPtr: number, classLen: number): void;
}

export function wasmSendFrame(wasm: ParamlibWasm, frame: Uint8Array): boolean {
    const ptr = wasm.alloc(frame.length);
    if (ptr === 0) return false;
    new Uint8Array(wasm.memory.buffer, ptr, frame.length).set(frame);
    wasm.serverSend(ptr, frame.length);
    wasm.free(ptr, frame.length);
    return true;
}

export function wasmSendSchema(wasm: ParamlibWasm, jsonUtf8: Uint8Array, className?: string): void {
    const contentPtr = wasm.alloc(jsonUtf8.length);
    if (contentPtr === 0) return;
    new Uint8Array(wasm.memory.buffer, contentPtr, jsonUtf8.length).set(jsonUtf8);

    const classBytes = className ? new TextEncoder().encode(className) : new Uint8Array(0);
    let classPtr = 0;
    if (classBytes.length > 0) {
        classPtr = wasm.alloc(classBytes.length);
        if (classPtr !== 0) {
            new Uint8Array(wasm.memory.buffer, classPtr, classBytes.length).set(classBytes);
        }
    }

    wasm.schemaUpdate(contentPtr, jsonUtf8.length, classPtr, classBytes.length);
    wasm.free(contentPtr, jsonUtf8.length);
    if (classPtr !== 0) wasm.free(classPtr, classBytes.length);
}
