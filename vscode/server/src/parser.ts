const WASM_RESERVED = new Set(['parse', 'wasm_alloc', 'wasm_free', 'memory']);

const HINT_DRIVEN_REFRESH: Record<string, string> = {
    'textDocument/semanticTokens/full':   'workspace/semanticTokens/refresh',
    'textDocument_semanticTokens_full':   'workspace/semanticTokens/refresh',
    'semanticTokensFull':                 'workspace/semanticTokens/refresh',
    'textDocument/semanticTokens/range':  'workspace/semanticTokens/refresh',
    'textDocument_semanticTokens_range':  'workspace/semanticTokens/refresh',
    'semanticTokensRange':                'workspace/semanticTokens/refresh',
    'textDocument/inlayHint':             'workspace/inlayHint/refresh',
    'textDocument_inlayHint':             'workspace/inlayHint/refresh',
    'inlayHint':                          'workspace/inlayHint/refresh',
    'textDocument/codeLens':              'workspace/codeLens/refresh',
    'textDocument_codeLens':              'workspace/codeLens/refresh',
    'codeLens':                           'workspace/codeLens/refresh',
    'textDocument/inlineValue':           'workspace/inlineValue/refresh',
    'textDocument_inlineValue':           'workspace/inlineValue/refresh',
    'inlineValue':                        'workspace/inlineValue/refresh',
    'textDocument/diagnostic':            'workspace/diagnostic/refresh',
    'textDocument_diagnostic':            'workspace/diagnostic/refresh',
    'diagnostic':                         'workspace/diagnostic/refresh',
};

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

    // Cache the last wasm-generated diagnostics per URI so they can be merged
    // into push-model publishDiagnostics notifications from the native LSP.
    private wasmDiagCache: Map<string, any[]> = new Map();

    constructor(
        private sendToWasm:           (message: any) => void,
        private resolveInternalWasm:  (name: string) => string,
        private sendRefreshNotifications: (uri: string, methods: string[]) => void,
        private readFile?:            (path: string) => Uint8Array,
        private resolveExternalWasm?: (source: string) => string,
        // Called after hints update with real params — server uses this to re-emit
        // a merged textDocument/publishDiagnostics when the pull-refresh doesn't fire.
        private onWasmDiagsReady?: (uri: string, diags: any[]) => void,
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
        await this.loadWasmModules();
        
        
        for (const [uri, doc] of this.openDocuments) {
            this.processDocument(uri, doc.params, doc.text);
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
        const newLspIndex = new Map<string, string[]>();

        for (const rule of this.rules) {
            if (!this.instances.has(rule.wasm_source)) {
                try {
                    const wasmPath = this.resolveWasmPath(rule.wasm_source);
                    console.error(`[parser-wasm] loading ${rule.wasm_source} from ${wasmPath}`);
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
                            wasm_log: (ptr: number, len: number) => {
                                const mem = instance.exports.memory as WebAssembly.Memory;
                                const msg = new TextDecoder().decode(new Uint8Array(mem.buffer, ptr, len));
                                console.error(`[parser-wasm:${rule.wasm_source}] ${msg}`);
                            }
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
                    const exportedNames: string[] = [];
                    for (const [name, val] of Object.entries(exp)) {
                        if (WASM_RESERVED.has(name) || typeof val !== 'function') continue;
                        lsp.set(name, (json) => callWasm(val as CallableFunction, json));
                        exportedNames.push(name);
                    }
                    console.error(`[parser-wasm] ${rule.wasm_source} exports: ${exportedNames.join(', ')}`);

                    this.instances.set(rule.wasm_source, {
                        parse: (input) => callWasm(parseFn, input),
                        lsp,
                    });
                } catch (e) {
                    console.error(`[parser-wasm] FAILED to load ${rule.wasm_source}:`, e);
                }
            }

            const inst = this.instances.get(rule.wasm_source);
            if (inst) {
                for (const name of inst.lsp.keys()) {
                    let list = newLspIndex.get(name);
                    if (!list) {
                        list = [];
                        newLspIndex.set(name, list);
                    }
                    list.push(rule.wasm_source);
                }
            }
        }
        this.lspIndex = newLspIndex;
    }

    public handleLsp(method: string, params: unknown, uri?: string): string[] {
        const [mangled, short] = lspMethodToExport(method);
        const sourcesMangled = this.lspIndex.get(mangled) || [];
        const sourcesShort   = this.lspIndex.get(short) || [];
        const uniqueSources  = Array.from(new Set([...sourcesMangled, ...sourcesShort]));

        if (method === 'textDocument/diagnostic') {
            console.error(`[paramlib:handleLsp] method=${method} mangled=${mangled} short=${short}`);
            console.error(`[paramlib:handleLsp] lspIndex keys: ${Array.from(this.lspIndex.keys()).join(', ') || '(empty)'}`);
            console.error(`[paramlib:handleLsp] sources found: ${uniqueSources.join(', ') || '(none)'}`);
        }

        const hints = uri ? (this.documentHints.get(uri) ?? []) : [];
        const doc = uri ? this.openDocuments.get(uri) : null;
        const docParams = doc?.params ?? [];
        const lineOffsets = doc?.text ? computeLineOffsets(doc.text) : [];

        if (method === 'textDocument/diagnostic') {
            console.error(`[paramlib:handleLsp] uri=${uri} hints.length=${hints.length}`);
            if (hints.length > 0) console.error(`[paramlib:handleLsp] first hint:`, JSON.stringify(hints[0]));
            else console.error(`[paramlib:handleLsp] NO HINTS — wasm parser has nothing to validate`);
        }

        const inputJson = JSON.stringify({ params, hints, docParams, lineOffsets });

        const results: string[] = [];
        for (const source of uniqueSources) {
            const inst = this.instances.get(source);
            const handler = inst?.lsp.get(mangled) ?? inst?.lsp.get(short);
            if (!handler) continue;

            const r = handler(inputJson);
            if (method === 'textDocument/diagnostic') {
                console.error(`[paramlib:handleLsp] wasm result from ${source}:`, r);
            }
            if (r !== null) results.push(r);
        }
        return results;
    }

    public getHints(uri: string): PrecomputedParserHint[] {
        return this.documentHints.get(uri) ?? [];
    }

    // Run the wasm diagnostic export synchronously against current hints.
    // Returns the merged array of diagnostic objects (may be empty).
    public getWasmDiagnostics(uri: string): any[] {
        const results = this.handleLsp('textDocument/diagnostic', {}, uri);
        const diags: any[] = [];
        for (const json of results) {
            try {
                const parsed = JSON.parse(json);
                const items = Array.isArray(parsed) ? parsed : (parsed?.items ?? []);
                diags.push(...items);
            } catch { /* ignore */ }
        }
        return diags;
    }

    // Merge wasm diagnostics with a set of native diagnostics.
    // Call this from the server whenever a textDocument/publishDiagnostics
    // notification is intercepted from the native LSP.
    public mergePublishDiagnostics(uri: string, nativeDiags: any[]): any[] {
        const cached = this.wasmDiagCache.get(uri) ?? [];
        return [...nativeDiags, ...cached];
    }

    public getRegisteredMethods(): string[] {
        return Array.from(this.lspIndex.keys());
    }

    public getHintDrivenRefreshNotifications(): string[] {
        const notifications = new Set<string>();
        for (const method of this.lspIndex.keys()) {
            const notification = HINT_DRIVEN_REFRESH[method];
            if (notification) notifications.add(notification);
        }
        return Array.from(notifications);
    }

    public processDocument(uri: string, params: DocumentParam[], rawText?: string): void {
        const existing = this.openDocuments.get(uri);
        this.openDocuments.set(uri, {
            params,
            text: rawText ?? existing?.text,
        });
        const text = rawText ?? existing?.text;

        // If this is an initial text-only call (no params yet), only run regex-based
        // rules.  We deliberately do NOT send workspace/diagnostic/refresh here —
        // the pull will fire before glob-matched hints (which need params) are ready,
        // so we hold off and let the second processDocument call (with real params)
        // own the refresh signal.
        const isParamlessOpen = params.length === 0 && rawText !== undefined;

        const hints: PrecomputedParserHint[] = [];

        for (const rule of this.rules) {
            const inst = this.instances.get(rule.wasm_source);
            if (!inst) continue;

            if (isRegexPattern(rule.pattern)) {
                if (!text) continue;
                const re = compileRegexPattern(rule.pattern);
                if (!re) continue;

                re.lastIndex = 0;
                let matchCount = 0;
                let match: RegExpExecArray | null;
                while ((match = re.exec(text)) !== null) {
                    matchCount++;
                    const captured = match[1] ?? match[0];
                    const result   = inst.parse(captured);
                    if (result !== null) {
                        const before    = text.slice(0, match.index);
                        const line      = (before.match(/\n/g) ?? []).length;
                        const lastNl    = before.lastIndexOf('\n');
                        const character = match.index - (lastNl + 1);

                        if (!isNaN(line) && !isNaN(character)) {
                            hints.push({
                                line,
                                character,
                                text:   result,
                                length: match[0].length,
                            });
                        }
                    } else {
                        console.error(`[paramlib:processDocument] parse() returned null for: ${JSON.stringify(captured.slice(0, 80))}`);
                    }
                    if (match[0].length === 0) re.lastIndex++;
                }
                console.error(`[paramlib:processDocument] pattern=${JSON.stringify(rule.pattern)} matchCount=${matchCount} uri=${uri}`);
            } else {
                for (const param of params) {
                    if (globMatch(rule.pattern, param.path)) {
                        const result = inst.parse(param.value);
                        if (result !== null) {
                            if (!isNaN(param.value_line) && !isNaN(param.value_character)) {
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
        }

        this.documentHints.set(uri, hints);

        console.error(`[paramlib:processDocument] uri=${uri} hints=${hints.length} rules=${this.rules.length} instances=${this.instances.size} isParamlessOpen=${isParamlessOpen}`);

        if (hints.length > 0 && !isParamlessOpen) {
            console.error(`[paramlib:processDocument] sending parserHints + refresh:`, JSON.stringify(hints.slice(0, 3)));
            this.sendToWasm({ jsonrpc: '2.0', method: '$/paramlib/parserHints', params: { uri, hints } });
            this.sendRefreshNotifications(uri, this.getHintDrivenRefreshNotifications());

            // Recompute wasm diagnostics now that hints are ready and notify the
            // server so it can re-emit a merged textDocument/publishDiagnostics.
            // This is the reliable push-model fallback for environments where
            // workspace/diagnostic/refresh doesn't trigger a re-pull.
            const wasmDiags = this.getWasmDiagnostics(uri);
            this.wasmDiagCache.set(uri, wasmDiags);
            console.error(`[paramlib:processDocument] wasm diag cache updated: ${wasmDiags.length} diags for ${uri}`);
            if (this.onWasmDiagsReady) this.onWasmDiagsReady(uri, wasmDiags);
        } else if (hints.length > 0 && isParamlessOpen) {
            console.error(`[paramlib:processDocument] skipping refresh on paramless open (waiting for getDocumentParams)`);
            this.sendToWasm({ jsonrpc: '2.0', method: '$/paramlib/parserHints', params: { uri, hints } });
        } else if (!isParamlessOpen) {
            // Real params pass but no hints — clear the wasm diag cache so stale
            // diagnostics don't persist after the user removes texture values.
            this.wasmDiagCache.set(uri, []);
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

function computeLineOffsets(text: string): number[] {
    const offsets: number[] = [];
    for (let i = 0; i < text.length; i++) {
        if (text[i] === '\n') offsets.push(i);
    }
    return offsets;
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
