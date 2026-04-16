export interface ParamlibWasm {
    memory:      WebAssembly.Memory;
    serverSend(ptr: number, len: number): void;
    alloc(len: number): number;
    free(ptr: number, len: number): void;
}

export function wasmSendFrame(wasm: ParamlibWasm, frame: Uint8Array): boolean {
    const ptr = wasm.alloc(frame.length);
    if (ptr === 0) return false;
    new Uint8Array(wasm.memory.buffer, ptr, frame.length).set(frame);
    wasm.serverSend(ptr, frame.length);
    wasm.free(ptr, frame.length);
    return true;
}