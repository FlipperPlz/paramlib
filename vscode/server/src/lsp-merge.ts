export type MergeStrategy = (base: unknown, extra: unknown, params?: any) => unknown;

function concatArrays(base: unknown, extra: unknown): unknown[] {
    const b = Array.isArray(base)  ? base  : [];
    const e = Array.isArray(extra) ? extra : [];
    return (b as unknown[]).concat(e as unknown[]);
}

function shallowMergeObjects(base: unknown, extra: unknown): unknown {
    if (typeof base  === 'object' && base  !== null &&
        typeof extra === 'object' && extra !== null) {
        return { ...(base as object), ...(extra as object) };
    }
    return extra ?? base;
}

// Semantic token data is a flat array of 5-integer tuples, delta-encoded:
//   [deltaLine, deltaStartChar, length, tokenType, tokenModifiers, ...]
// where deltaLine/deltaStartChar are relative to the *previous* token (or
// (0,0) for the first token in the array).
//
// Two independently-produced delta-encoded arrays cannot be naively
// concatenated or merge-sorted: WASM tokens for sub-ranges inside a proc
// texture string overlap the native stringLiteral token that covers the
// whole value (e.g. "#(argb,…)").  The LSP spec forbids overlapping tokens
// and VS Code paints whichever token sorts first over the rest.
//
// Fix: decode both streams to absolute positions, then for every base token
// that overlaps one or more WASM tokens, split it into gap-fragments around
// those WASM ranges instead of emitting it whole.  The fragments plus the
// WASM tokens are then sorted and re-encoded as a single delta sequence.
function semTokenMerge(base: any, extra: any): unknown {
    const bData: number[] = Array.isArray(base?.data)  ? base.data  : [];
    const eData: number[] = Array.isArray(extra?.data) ? extra.data : [];
    if (bData.length === 0) return { data: eData };
    if (eData.length === 0) return { data: bData };

    interface AbsTok { line: number; char: number; len: number; type: number; mod: number; }

    function decode(data: number[]): AbsTok[] {
        const out: AbsTok[] = [];
        let line = 0, char = 0;
        for (let i = 0; i + 4 < data.length; i += 5) {
            const dl = data[i], dc = data[i+1];
            line += dl;
            char  = dl === 0 ? char + dc : dc;
            out.push({ line, char, len: data[i+2], type: data[i+3], mod: data[i+4] });
        }
        return out;
    }

    function encode(toks: AbsTok[]): number[] {
        const out: number[] = [];
        let prevLine = 0, prevChar = 0;
        for (const t of toks) {
            const dl = t.line - prevLine;
            out.push(dl, dl === 0 ? t.char - prevChar : t.char, t.len, t.type, t.mod);
            prevLine = t.line;
            prevChar = t.char;
        }
        return out;
    }

    const bToks = decode(bData);
    const eToks = decode(eData);

    // For each base token, punch out any sub-ranges covered by WASM tokens
    // on the same line, emitting only the gap fragments that remain.
    const baseParts: AbsTok[] = [];
    for (const b of bToks) {
        const bEnd = b.char + b.len;

        // WASM tokens that intersect this base token (same line, overlapping char range).
        const overlapping = eToks
            .filter(e => e.line === b.line && e.char < bEnd && e.char + e.len > b.char)
            .sort((x, y) => x.char - y.char);

        if (overlapping.length === 0) {
            baseParts.push(b);
            continue;
        }

        // Emit base fragments in the gaps between (and around) the WASM tokens.
        let cursor = b.char;
        for (const e of overlapping) {
            if (cursor < e.char) {
                baseParts.push({ line: b.line, char: cursor, len: e.char - cursor, type: b.type, mod: b.mod });
            }
            cursor = Math.max(cursor, e.char + e.len);
        }
        if (cursor < bEnd) {
            baseParts.push({ line: b.line, char: cursor, len: bEnd - cursor, type: b.type, mod: b.mod });
        }
    }

    // Merge the (now non-overlapping) base fragments with all WASM tokens and sort.
    const allToks = [...baseParts, ...eToks].sort((a, b) =>
        a.line !== b.line ? a.line - b.line : a.char - b.char
    );

    return { data: encode(allToks) };
}

const strategies = new Map<string, MergeStrategy>([
    ['textDocument/hover', (base: any, extra: any) => {
        const bVal: string = base?.contents?.value
            ?? (typeof base?.contents  === 'string' ? base.contents  : '')
            ?? '';
        const eVal: string = extra?.contents?.value
            ?? (typeof extra?.contents === 'string' ? extra.contents : '')
            ?? '';
        const merged = [bVal, eVal].filter(Boolean).join('\n\n---\n\n');
        return {
            contents: { kind: 'markdown', value: merged },
            range: base?.range ?? extra?.range,
        };
    }],

    ['textDocument/completion', (base: any, extra: any) => {
        const bItems      = Array.isArray(base)  ? base  : (base?.items  ?? []);
        const eItems      = Array.isArray(extra) ? extra : (extra?.items ?? []);
        const bIncomplete = base?.isIncomplete  ?? false;
        const eIncomplete = extra?.isIncomplete ?? false;
        return { isIncomplete: bIncomplete || eIncomplete, items: [...bItems, ...eItems] };
    }],

   
    ['textDocument/documentSymbol',         (b, e) => concatArrays(b, e)],
    ['textDocument/references',             (b, e) => concatArrays(b, e)],
    ['textDocument/inlayHint',              (b, e) => concatArrays(b, e)],
    ['textDocument/codeLens',               (b, e) => concatArrays(b, e)],
    ['textDocument/codeAction',             (b, e) => concatArrays(b, e)],
    ['textDocument/formatting',             (b, e) => concatArrays(b, e)],
    ['textDocument/rangeFormatting',        (b, e) => concatArrays(b, e)],
    ['textDocument/onTypeFormatting',       (b, e) => concatArrays(b, e)],
    ['textDocument/documentHighlight',      (b, e) => concatArrays(b, e)],
    ['textDocument/documentLink',           (b, e) => concatArrays(b, e)],
    ['textDocument/documentColor',          (b, e) => concatArrays(b, e)],
    ['textDocument/colorPresentation',      (b, e) => concatArrays(b, e)],
    ['textDocument/foldingRange',           (b, e) => concatArrays(b, e)],
    ['textDocument/selectionRange',         (b, e) => concatArrays(b, e)],
    ['textDocument/moniker',                (b, e) => concatArrays(b, e)],
    ['textDocument/prepareCallHierarchy',   (b, e) => concatArrays(b, e)],
    ['textDocument/prepareTypeHierarchy',   (b, e) => concatArrays(b, e)],
    ['callHierarchy/incomingCalls',         (b, e) => concatArrays(b, e)],
    ['callHierarchy/outgoingCalls',         (b, e) => concatArrays(b, e)],
    ['typeHierarchy/supertypes',            (b, e) => concatArrays(b, e)],
    ['typeHierarchy/subtypes',              (b, e) => concatArrays(b, e)],
    ['workspace/symbol',                    (b, e) => concatArrays(b, e)],

    
    ['textDocument/definition',     locationMerge],
    ['textDocument/declaration',    locationMerge],
    ['textDocument/typeDefinition', locationMerge],
    ['textDocument/implementation', locationMerge],

    
    ['textDocument/diagnostic', (base: any, extra: any) => {
        const bItems = Array.isArray(base?.items) ? base.items : (Array.isArray(base) ? base : []);
        const eItems = Array.isArray(extra?.items) ? extra.items : (Array.isArray(extra) ? extra : []);
        return { kind: 'full', items: [...bItems, ...eItems] };
    }],

    ['textDocument/semanticTokens/full',  semTokenMerge],
    ['textDocument/semanticTokens/range', semTokenMerge],

    
    ['textDocument/rename', (base: any, extra: any) => {
        const merged: Record<string, unknown[]> = { ...(base?.changes ?? {}) };
        for (const [uri, edits] of Object.entries(extra?.changes ?? {}) as [string, unknown[]][]) {
            merged[uri] = merged[uri] ? (merged[uri] as unknown[]).concat(edits) : edits;
        }
        return { changes: merged };
    }],

    
    ['textDocument/linkedEditingRange', (base: any, extra: any) => ({
        ranges:      concatArrays(base?.ranges, extra?.ranges),
        wordPattern: base?.wordPattern ?? extra?.wordPattern,
    })],

    
    ['textDocument/signatureHelp', (base: any, extra: any) => {
        const bSigs = base?.signatures?.length  ?? 0;
        const eSigs = extra?.signatures?.length ?? 0;
        if (bSigs === 0) return extra;
        if (eSigs === 0) return base;
        return {
            signatures:      [...(base.signatures ?? []), ...(extra.signatures ?? [])],
            activeSignature: base.activeSignature ?? extra.activeSignature ?? 0,
            activeParameter: base.activeParameter ?? extra.activeParameter ?? 0,
        };
    }],

    
    ['textDocument/prepareRename',  (b: any, e: any) => b ?? e],
    ['workspace/executeCommand',    (b: any, e: any) => b ?? e],
]);

function locationMerge(base: any, extra: any): unknown {
    const b = base  ? (Array.isArray(base)  ? base  : [base])  : [];
    const e = extra ? (Array.isArray(extra) ? extra : [extra]) : [];
    const merged = [...b, ...e];
    return merged.length === 1 ? merged[0] : merged;
}

export function registerMergeStrategy(method: string, fn: MergeStrategy): void {
    strategies.set(method, fn);
}

function isValidRange(r: any): boolean {
    if (!(r && typeof r === 'object' &&
           r.start && typeof r.start === 'object' &&
           typeof r.start.line === 'number' && typeof r.start.character === 'number' &&
           r.end && typeof r.end === 'object' &&
           typeof r.end.line === 'number' && typeof r.end.character === 'number')) {
        return false;
    }
    if (r.start.line === r.end.line && r.start.character === r.end.character) {
        return false;
    }
    return !(r.start.line > r.end.line || (r.start.line === r.end.line && r.start.character > r.end.character));

}

function validateColorInformation(items: any[]): any[] {
    const valid = items.filter(item => {
        if (!item || typeof item !== 'object') return false;
        if (!isValidRange(item.range)) return false;
        const c = item.color;
        return !(!c || typeof c !== 'object' ||
            typeof c.red !== 'number' || typeof c.green !== 'number' ||
            typeof c.blue !== 'number' || typeof c.alpha !== 'number');

    });

    const seen = new Map<string, any>();
    for (const item of valid) {
        const key = `${item.range.start.line}:${item.range.start.character}`;
        const existing = seen.get(key);
        if (!existing) {
            seen.set(key, item);
        } else {
            const extLen = (existing.range.end.line - existing.range.start.line) * 1000 + (existing.range.end.character - existing.range.start.character);
            const itemLen = (item.range.end.line - item.range.start.line) * 1000 + (item.range.end.character - item.range.start.character);
            if (itemLen > extLen) {
                seen.set(key, item);
            }
        }
    }
    return Array.from(seen.values());
}
function transformToFloatColor(text: string): string {
    const match = text.match(/\{?\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*\}?/);
    if (match) {
        const f = (n: string) => parseFloat(n).toFixed(4).replace(/\.?0+$/, '');
        const str = `${f(match[1])}, ${f(match[2])}, ${f(match[3])}, ${f(match[4])}`;
        return text.startsWith('{') ? `{${str}}` : str;
    }
    return text;
}

export function mergeLspResults(method: string, base: unknown, additions: string[], params?: any): unknown {
    if (additions.length === 0) return base;

    let result = base;

    for (const json of additions) {
        try {
            let extra = JSON.parse(json);
            if (extra === null || extra === undefined) continue;

            if (method === 'textDocument/documentColor' && Array.isArray(extra)) {
                extra = validateColorInformation(extra);
            }

            if (result === null || result === undefined) {
                const strategy = strategies.get(method);
                result = strategy ? strategy(null, extra, params) : extra;
                continue;
            }

            const strategy = strategies.get(method);
            if (strategy) {
                result = strategy(result, extra, params);

                if (method === 'textDocument/documentColor' && Array.isArray(result)) {
                    result = validateColorInformation(result);
                }
            } else if (Array.isArray(result) && Array.isArray(extra)) {

                result = (result as unknown[]).concat(extra as unknown[]);
            } else {
                result = shallowMergeObjects(result, extra);
            }
        } catch (e) {
            console.error(`[paramlib] mergeLspResults: failed to merge "${method}":`, e);
        }
    }

    return result;
}
