const WASM_RESERVED = new Set(['parse', 'wasm_alloc', 'wasm_free', 'memory']);

export interface ParserRule {
    pattern: string;
    wasm_source: string;
}

export interface DocumentParam {
    path: string;
    value: string;
    line: number;
    character: number;
    value_line: number;
    value_character: number;
    elem_positions: { line: number, character: number }[];
}

export interface PrecomputedParserHint {
    line: number;
    character: number;
    text: string;
    length: number;
}


interface ParserInstance {
    parse: (input: string) => string | null;
    lsp: Map<string, (paramsJson: string) => string | null>;
}

interface OpenDocument {
    params: DocumentParam[];
    text?: string;
}

export class ParserManager {
    private rules:          ParserRule[]                          = [];
    private instances:      Map<string, ParserInstance>           = new Map();
    private documentHints:  Map<string, PrecomputedParserHint[]>  = new Map();

    private openDocuments:  Map<string, OpenDocument>             = new Map();

    private lspIndex: Map<string, string[]> = new Map();

    constructor(
        private sendToWasm:           (message: any) => void,
        private resolveInternalWasm:  (name: string) => string,
        private sendColorRefresh:     (uri: string)  => void,
        private readFile?:            (path: string) => Uint8Array,
        private resolveExternalWasm?: (source: string) => string,
    ) {}

    public openDocument(uri: string, text: string): void {
        const existing = this.openDocuments.get(uri);
        this.openDocuments.set(uri, { params: existing?.params ?? [], text });
    }

    public closeDocument(uri: string): void {
        this.openDocuments.delete(uri);
        this.documentHints.delete(uri);
    }

    public async updateRules(rules: ParserRule[]): Promise<void> {
        this.rules = rules;
        this.lspIndex.clear();
        await this.loadWasmModules();
        for (const [uri, doc] of this.openDocuments) {
            await this.processDocument(uri, doc.params, doc.text);
        }
    }

    private resolveWasmPath(source: string): string {
        if (source.startsWith('internal:')) {
            const resolved = this.resolveInternalWasm(source.slice('internal:'.length));
            return resolved;
        }
        if (this.resolveExternalWasm) {
            const resolved = this.resolveExternalWasm(source);
            return resolved;
        }
        return source;
    }

    private async loadWasmModules(): Promise<void> {
        for (const rule of this.rules) {
            if (this.instances.has(rule.wasm_source)) continue;
            try {
                const wasmPath = this.resolveWasmPath(rule.wasm_source);
                let bytes: ArrayBuffer;

                if (this.readFile && !wasmPath.startsWith('http')) {
                    bytes = this.readFile(wasmPath).buffer as ArrayBuffer;
                } else {
                    const response = await fetch(wasmPath);
                    if (!response.ok) throw new Error(`HTTP ${response.status}`);
                    bytes = await response.arrayBuffer();
                }

                const { instance } = await WebAssembly.instantiate(bytes, { 
                    env: {
                        wasm_log: (_ptr: number, _len: number) => {}
                    } 
                });
                const exp = instance.exports;

                const parseFn = exp.parse      as CallableFunction | undefined;
                const allocFn = exp.wasm_alloc as CallableFunction | undefined;
                const freeFn  = exp.wasm_free  as CallableFunction | undefined;
                const memory  = exp.memory     as WebAssembly.Memory;

                if (typeof parseFn !== 'function') {
                    console.error(`[parser-wasm] ${rule.wasm_source}: missing parse export`);
                    continue;
                }

                const callWasm = (fn: CallableFunction, input: string): string | null => {
                    const enc     = new TextEncoder();
                    const inBytes = enc.encode(input);
                    const inPtr: number = allocFn ? allocFn(inBytes.length) : 0;
                    if (!inPtr) return null;
                    new Uint8Array(memory.buffer, inPtr, inBytes.length).set(inBytes);

                    const outMax           = 65536;
                    const outPtr: number   = allocFn ? allocFn(outMax) : 0;
                    if (!outPtr) { freeFn?.(inPtr, inBytes.length); return null; }

                    const outLen: number = fn(inPtr, inBytes.length, outPtr, outMax);
                    const result = outLen >= 0
                        ? new TextDecoder().decode(new Uint8Array(memory.buffer, outPtr, outLen))
                        : null;

                    freeFn?.(inPtr, inBytes.length);
                    freeFn?.(outPtr, outMax);
                    return result;
                };

                const lsp = new Map<string, (json: string) => string | null>();
                for (const [name, val] of Object.entries(exp)) {
                    if (WASM_RESERVED.has(name) || typeof val !== 'function') continue;
                    lsp.set(name, (json) => callWasm(val as CallableFunction, json));
                }

                this.instances.set(rule.wasm_source, {
                    parse: (input) => callWasm(parseFn, input),
                    lsp,
                });

                for (const name of lsp.keys()) {
                    let list = this.lspIndex.get(name);
                    if (!list) {
                        list = [];
                        this.lspIndex.set(name, list);
                    }
                    list.push(rule.wasm_source);
                }

            } catch (e) {
                console.error(`[parser-wasm] failed to load ${rule.wasm_source}:`, e);
            }
        }
    }

    public handleLsp(method: string, params: unknown, uri?: string): string[] {
        const [mangled, short] = lspMethodToExport(method);
        const sources = (this.lspIndex.get(mangled) || []).concat(this.lspIndex.get(short) || []);
        const uniqueSources = Array.from(new Set(sources));
        
        const doc = uri ? this.openDocuments.get(uri) : null;
        const hints = uri ? (this.documentHints.get(uri) ?? []) : [];
        const docParams = doc?.params ?? [];
        const inputJson = JSON.stringify({ params, hints, docParams });

        const results: string[] = [];
        for (const source of uniqueSources) {
            const inst = this.instances.get(source);
            if (!inst) continue;

            const handler = inst.lsp.get(mangled) ?? inst.lsp.get(short);
            if (!handler) continue;

            const r = handler(inputJson);
            if (r !== null) results.push(r);
        }
        return results;
    }

    public getHints(uri: string): PrecomputedParserHint[] {
        return this.documentHints.get(uri) ?? [];
    }

    public async processDocument(uri: string, params: DocumentParam[], rawText?: string): Promise<void> {
        const existing = this.openDocuments.get(uri);
        this.openDocuments.set(uri, {
            params,
            text: rawText ?? existing?.text,
        });
        const text = rawText ?? existing?.text;

        const hints: PrecomputedParserHint[] = [];

        for (const rule of this.rules) {
            const inst = this.instances.get(rule.wasm_source);
            if (!inst) continue;

            if (isRegexPattern(rule.pattern)) {
                if (!text) continue;
                const re = compileRegexPattern(rule.pattern);
                if (!re) continue;

                re.lastIndex = 0;
                let match: RegExpExecArray | null;
                while ((match = re.exec(text)) !== null) {
                    const captured = match[1] ?? match[0];
                    const result   = inst.parse(captured);
                    if (result !== null) {
                        const before    = text.slice(0, match.index);
                        const line      = (before.match(/\n/g) ?? []).length;
                        const lastNl    = before.lastIndexOf('\n');
                        const character = match.index - (lastNl + 1);
                        hints.push({
                            line,
                            character,
                            text:   result,
                            length: match[0].length,
                        });
                    }
                    if (match[0].length === 0) re.lastIndex++;
                }
            } else {
                for (const param of params) {
                    if (globMatch(rule.pattern, param.path)) {
                        const result = inst.parse(param.value);
                        if (result !== null) {
                            hints.push({
                                line:      param.value_line,
                                character: param.value_character,
                                text:      result,
                                length:    param.value.length,
                            });
                        }
                    }
                }
            }
        }

        this.documentHints.set(uri, hints);

        if (hints.length > 0) {
            this.sendToWasm({ jsonrpc: '2.0', method: '$/paramlib/parserHints', params: { uri, hints } });
            this.sendColorRefresh(uri);
        }
    }
}

function lspMethodToExport(method: string): [string, string] {
    const mangled = method.replace(/\//g, '_');
    const short   = method.slice(method.lastIndexOf('/') + 1);
    return [mangled, short];
}

function isRegexPattern(pattern: string): boolean {
    return pattern.includes('(') || pattern.includes('$$');
}

function compileRegexPattern(pattern: string): RegExp | null {
    const src = pattern.replace(/\$\$/g, '').trim();
    try {
        return new RegExp(src, 'g');
    } catch {
        console.error(`[paramlib] Invalid regex pattern: ${pattern}`);
        return null;
    }
}

function globMatch(pattern: string, str: string): boolean {
    const escaped = pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&');
    const re = escaped
        .replace(/\*\*/g, '\x00')
        .replace(/\*/g, '[^.]*')
        .replace(/\x00/g, '.*')
        .replace(/\?/g, '.');
    return new RegExp(`^${re}$`).test(str);
}
