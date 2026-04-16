export interface ParamlibWasm {
    memory:      WebAssembly.Memory;
    wasmInit():  void;
    wasmStep():  number;
    serverSend(ptr: number, len: number): void;
    jsAlloc(len: number): number;
    jsFree(ptr: number, len: number): void;
}

export function wasmSendFrame(wasm: ParamlibWasm, frame: Uint8Array): boolean {
    const ptr = wasm.jsAlloc(frame.length);
    if (ptr === 0) return false;
    new Uint8Array(wasm.memory.buffer, ptr, frame.length).set(frame);
    wasm.serverSend(ptr, frame.length);
    wasm.jsFree(ptr, frame.length);
    wasm.wasmStep();
    return true;
}