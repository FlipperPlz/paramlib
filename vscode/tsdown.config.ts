import { defineConfig } from 'tsdown'
import pkg from './package.json' with { type: 'json' }
const { name, publisher, version } = pkg

const PRODUCTION = process.env.NODE_ENV === "production";

const extensionURL = PRODUCTION
    ? `https://${publisher}.vscode-unpkg.net/${publisher}/${name}/${version}/extension/server/dist/`
    : undefined;
const schemasURL = PRODUCTION
    ? `https://${publisher}.vscode-unpkg.net/${publisher}/${name}/${version}/extension/schemas/`
    : undefined;

const wasmAssets = [
    {
        from: '../zig-out/wasm/paramlib-lsp.wasm',
        to: 'server/dist',
    },
    {
        from: '../zig-out/parsers/color.wasm',
        to: 'server/dist/parsers',
    },
]

export default defineConfig([
    {
        entry: 'client/src/clientNode.ts',
        output: 'client/dist/clientNode.js',
        format: 'cjs',
        platform: 'node',
        externals: ['vscode'],
        define: {
            __DEV_MODE__: JSON.stringify(!PRODUCTION),
        },
        clean: true,
    },
    {
        entry: 'client/src/clientBrowser.ts',
        output: 'client/dist/clientBrowser.js',
        format: 'cjs',
        platform: 'neutral',
        externals: ['vscode'],
        alias: {
            path: 'path-browserify',
        },
        define: {
            __DEV_MODE__: JSON.stringify(!PRODUCTION),
            __SCHEMAS_URL__: JSON.stringify(schemasURL ?? null),
        },
        clean: true,
    },
    {
        entry: 'server/src/serverNode.ts',
        output: 'server/dist/serverNode.js',
        format: 'cjs',
        platform: 'node',
        copy: wasmAssets,
        clean: true,
    },
    {
        entry: 'server/src/serverBrowser.ts',
        output: 'server/dist/serverBrowser.js',
        format: 'cjs',
        platform: 'neutral',
        define: {
            __DEV_MODE__: JSON.stringify(!PRODUCTION),
            __EXTENSION_URL__: JSON.stringify(extensionURL ?? null),
        },
        copy: wasmAssets,
        clean: true,
    }
])
