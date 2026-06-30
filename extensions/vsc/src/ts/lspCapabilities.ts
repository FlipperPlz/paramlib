interface CapabilitySpec {
    capKey: string;
    value?: unknown;
}

function semTokensFull() {
    return {
        legend: {
            tokenTypes:     ['keyword', 'comment', 'variable', 'string', 'operator', 'number'],
            tokenModifiers: [],
        },
        full: true, range: false,
    };
}

function semTokensRange() {
    return {
        legend: {
            tokenTypes:     ['keyword', 'comment', 'variable', 'string', 'operator', 'number'],
            tokenModifiers: [],
        },
        full: false, range: true,
    };
}
const METHOD_TO_CAP: Record<string, CapabilitySpec[]> = {
    'textDocument/hover':                  [{ capKey: 'hoverProvider', value: true }],
    'textDocument_hover':                  [{ capKey: 'hoverProvider', value: true }],
    'hover':                               [{ capKey: 'hoverProvider', value: true }],
    'textDocument/completion':             [{ capKey: 'completionProvider', value: { triggerCharacters: [' ', '\t'] } }],
    'textDocument_completion':             [{ capKey: 'completionProvider', value: { triggerCharacters: [' ', '\t'] } }],
    'completion':                          [{ capKey: 'completionProvider', value: { triggerCharacters: [' ', '\t'] } }],
    'textDocument/signatureHelp':          [{ capKey: 'signatureHelpProvider', value: { triggerCharacters: ['(', ','] } }],
    'textDocument_signatureHelp':          [{ capKey: 'signatureHelpProvider', value: { triggerCharacters: ['(', ','] } }],
    'signatureHelp':                       [{ capKey: 'signatureHelpProvider', value: { triggerCharacters: ['(', ','] } }],
    'textDocument/definition':             [{ capKey: 'definitionProvider', value: true }],
    'textDocument_definition':             [{ capKey: 'definitionProvider', value: true }],
    'definition':                          [{ capKey: 'definitionProvider', value: true }],
    'textDocument/declaration':            [{ capKey: 'declarationProvider', value: true }],
    'textDocument_declaration':            [{ capKey: 'declarationProvider', value: true }],
    'declaration':                         [{ capKey: 'declarationProvider', value: true }],
    'textDocument/typeDefinition':         [{ capKey: 'typeDefinitionProvider', value: true }],
    'textDocument_typeDefinition':         [{ capKey: 'typeDefinitionProvider', value: true }],
    'typeDefinition':                      [{ capKey: 'typeDefinitionProvider', value: true }],
    'textDocument/implementation':         [{ capKey: 'implementationProvider', value: true }],
    'textDocument_implementation':         [{ capKey: 'implementationProvider', value: true }],
    'implementation':                      [{ capKey: 'implementationProvider', value: true }],
    'textDocument/references':             [{ capKey: 'referencesProvider', value: true }],
    'textDocument_references':             [{ capKey: 'referencesProvider', value: true }],
    'references':                          [{ capKey: 'referencesProvider', value: true }],
    'textDocument/documentHighlight':      [{ capKey: 'documentHighlightProvider', value: true }],
    'textDocument_documentHighlight':      [{ capKey: 'documentHighlightProvider', value: true }],
    'documentHighlight':                   [{ capKey: 'documentHighlightProvider', value: true }],
    'textDocument/documentSymbol':         [{ capKey: 'documentSymbolProvider', value: true }],
    'textDocument_documentSymbol':         [{ capKey: 'documentSymbolProvider', value: true }],
    'documentSymbol':                      [{ capKey: 'documentSymbolProvider', value: true }],
    'textDocument/codeAction':             [{ capKey: 'codeActionProvider', value: true }],
    'textDocument_codeAction':             [{ capKey: 'codeActionProvider', value: true }],
    'codeAction':                          [{ capKey: 'codeActionProvider', value: true }],
    'textDocument/codeLens':               [{ capKey: 'codeLensProvider', value: { resolveProvider: false } }],
    'textDocument_codeLens':               [{ capKey: 'codeLensProvider', value: { resolveProvider: false } }],
    'codeLens':                            [{ capKey: 'codeLensProvider', value: { resolveProvider: false } }],
    'textDocument/documentLink':           [{ capKey: 'documentLinkProvider', value: { resolveProvider: false } }],
    'textDocument_documentLink':           [{ capKey: 'documentLinkProvider', value: { resolveProvider: false } }],
    'documentLink':                        [{ capKey: 'documentLinkProvider', value: { resolveProvider: false } }],
    'textDocument/documentColor':          [{ capKey: 'colorProvider', value: true }, { capKey: 'documentColorProvider', value: true }],
    'textDocument_documentColor':          [{ capKey: 'colorProvider', value: true }, { capKey: 'documentColorProvider', value: true }],
    'documentColor':                       [{ capKey: 'colorProvider', value: true }, { capKey: 'documentColorProvider', value: true }],
    'textDocument/colorPresentation':      [{ capKey: 'colorProvider', value: true }, { capKey: 'documentColorProvider', value: true }],
    'colorPresentation':                   [{ capKey: 'colorProvider', value: true }, { capKey: 'documentColorProvider', value: true }],
    'textDocument/formatting':             [{ capKey: 'documentFormattingProvider', value: true }],
    'textDocument_formatting':             [{ capKey: 'documentFormattingProvider', value: true }],
    'formatting':                          [{ capKey: 'documentFormattingProvider', value: true }],
    'textDocument/rangeFormatting':        [{ capKey: 'documentRangeFormattingProvider', value: true }],
    'textDocument_rangeFormatting':        [{ capKey: 'documentRangeFormattingProvider', value: true }],
    'rangeFormatting':                     [{ capKey: 'documentRangeFormattingProvider', value: true }],
    'textDocument/onTypeFormatting':       [{ capKey: 'documentOnTypeFormattingProvider', value: { firstTriggerCharacter: ';' } }],
    'textDocument_onTypeFormatting':       [{ capKey: 'documentOnTypeFormattingProvider', value: { firstTriggerCharacter: ';' } }],
    'onTypeFormatting':                    [{ capKey: 'documentOnTypeFormattingProvider', value: { firstTriggerCharacter: ';' } }],
    'textDocument/rename':                 [{ capKey: 'renameProvider', value: true }],
    'textDocument_rename':                 [{ capKey: 'renameProvider', value: true }],
    'rename':                              [{ capKey: 'renameProvider', value: true }],
    'textDocument/foldingRange':           [{ capKey: 'foldingRangeProvider', value: true }],
    'textDocument_foldingRange':           [{ capKey: 'foldingRangeProvider', value: true }],
    'foldingRange':                        [{ capKey: 'foldingRangeProvider', value: true }],
    'textDocument/selectionRange':         [{ capKey: 'selectionRangeProvider', value: true }],
    'textDocument_selectionRange':         [{ capKey: 'selectionRangeProvider', value: true }],
    'selectionRange':                      [{ capKey: 'selectionRangeProvider', value: true }],
    'textDocument/linkedEditingRange':     [{ capKey: 'linkedEditingRangeProvider', value: true }],
    'textDocument_linkedEditingRange':     [{ capKey: 'linkedEditingRangeProvider', value: true }],
    'linkedEditingRange':                  [{ capKey: 'linkedEditingRangeProvider', value: true }],
    'textDocument/semanticTokens/full':    [{ capKey: 'semanticTokensProvider', value: semTokensFull() }],
    'textDocument_semanticTokens_full':    [{ capKey: 'semanticTokensProvider', value: semTokensFull() }],
    'semanticTokens_full':                 [{ capKey: 'semanticTokensProvider', value: semTokensFull() }],
    'semanticTokensFull':                  [{ capKey: 'semanticTokensProvider', value: semTokensFull() }],
    'textDocument/semanticTokens/range':   [{ capKey: 'semanticTokensProvider', value: semTokensRange() }],
    'textDocument_semanticTokens_range':   [{ capKey: 'semanticTokensProvider', value: semTokensRange() }],
    'semanticTokens_range':                [{ capKey: 'semanticTokensProvider', value: semTokensRange() }],
    'semanticTokensRange':                 [{ capKey: 'semanticTokensProvider', value: semTokensRange() }],
    'textDocument/inlayHint':              [{ capKey: 'inlayHintProvider', value: true }],
    'textDocument_inlayHint':              [{ capKey: 'inlayHintProvider', value: true }],
    'inlayHint':                           [{ capKey: 'inlayHintProvider', value: true }],
    'textDocument/inlineValue':            [{ capKey: 'inlineValueProvider', value: true }],
    'textDocument_inlineValue':            [{ capKey: 'inlineValueProvider', value: true }],
    'inlineValue':                         [{ capKey: 'inlineValueProvider', value: true }],
    'textDocument/moniker':                [{ capKey: 'monikerProvider', value: true }],
    'textDocument_moniker':                [{ capKey: 'monikerProvider', value: true }],
    'moniker':                             [{ capKey: 'monikerProvider', value: true }],
    'textDocument/prepareCallHierarchy':   [{ capKey: 'callHierarchyProvider', value: true }],
    'textDocument_prepareCallHierarchy':   [{ capKey: 'callHierarchyProvider', value: true }],
    'prepareCallHierarchy':                [{ capKey: 'callHierarchyProvider', value: true }],
    'textDocument/prepareTypeHierarchy':   [{ capKey: 'typeHierarchyProvider', value: true }],
    'textDocument_prepareTypeHierarchy':   [{ capKey: 'typeHierarchyProvider', value: true }],
    'prepareTypeHierarchy':                [{ capKey: 'typeHierarchyProvider', value: true }],
    'textDocument/diagnostic':             [{ capKey: 'diagnosticProvider', value: { interFileDependencies: false, workspaceDiagnostics: false } }],
    'textDocument_diagnostic':             [{ capKey: 'diagnosticProvider', value: { interFileDependencies: false, workspaceDiagnostics: false } }],
    'diagnostic':                          [{ capKey: 'diagnosticProvider', value: { interFileDependencies: false, workspaceDiagnostics: false } }],
    'workspace/symbol':                    [{ capKey: 'workspaceSymbolProvider', value: true }],
    'workspace_symbol':                    [{ capKey: 'workspaceSymbolProvider', value: true }],
    'workspaceSymbol':                     [{ capKey: 'workspaceSymbolProvider', value: true }],
};


export function buildCapabilitiesPatch(registeredMethods: string[]): Record<string, unknown> {
    const patch: Record<string, unknown> = {};

    for (const method of registeredMethods) {
        const specs = METHOD_TO_CAP[method];
        if (!specs) continue;
        for (const spec of specs) {
            if (patch[spec.capKey] === undefined) {
                patch[spec.capKey] = spec.value ?? true;
            }
        }
    }

    return patch;
}
