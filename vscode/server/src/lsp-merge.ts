export type MergeStrategy = (base: unknown, extra: unknown) => unknown;

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

    
    ['textDocument/semanticTokens/full', (base: any, extra: any) => ({
        data: [...(base?.data ?? []), ...(extra?.data ?? [])],
    })],
    ['textDocument/semanticTokens/range', (base: any, extra: any) => ({
        data: [...(base?.data ?? []), ...(extra?.data ?? [])],
    })],

    
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
    // Reject empty ranges (start == end) as they cause "Illegal argument: range" in VS Code color providers
    if (r.start.line === r.end.line && r.start.character === r.end.character) {
        return false;
    }
    // Ensure start is before or at end
    if (r.start.line > r.end.line || (r.start.line === r.end.line && r.start.character > r.end.character)) {
        return false;
    }
    return true;
}

function validateColorInformation(items: any[]): any[] {
    const valid = items.filter(item => {
        if (!item || typeof item !== 'object') return false;
        if (!isValidRange(item.range)) return false;
        const c = item.color;
        if (!c || typeof c !== 'object' || 
            typeof c.red !== 'number' || typeof c.green !== 'number' || 
            typeof c.blue !== 'number' || typeof c.alpha !== 'number') {
            return false;
        }
        return true;
    });

    // De-duplicate: if multiple colors start at the same position, prefer the one with the longer range
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

export function mergeLspResults(method: string, base: unknown, additions: string[]): unknown {
    if (additions.length === 0) return base;

    let result = base;

    for (const json of additions) {
        try {
            let extra = JSON.parse(json);
            if (extra === null || extra === undefined) continue;

            // Specific validation for color results
            if (method === 'textDocument/documentColor' && Array.isArray(extra)) {
                extra = validateColorInformation(extra);
            }

            if (result === null || result === undefined) {
                result = extra;
                continue;
            }

            const strategy = strategies.get(method);
            if (strategy) {
                result = strategy(result, extra);

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
