// Bundles all four entry points using Bun's built-in bundler.
//
//   src/ts/extension.ts                → dist/extension.js          (Node extension host)
//   src/ts/web/extension.ts            → dist/web/extension.js      (browser extension host)
//   src/ts/server/server.ts            → dist/server.js             (LSP server, Node IPC)
//   src/ts/server/browserServerMain.ts → dist/web/server.js         (LSP server, Web Worker)

import { watch } from 'fs';

const isWatch = process.argv.includes('--watch');
const production = process.argv.includes('--production');

const common: Partial<Bun.BuildConfig> = {
  minify: production,
  sourcemap: production ? ('none' as const) : ('inline' as const),
  define: { global: 'globalThis' },
  external: ['vscode'],
};

const targets: Bun.BuildConfig[] = [
  {
    entrypoints: ['src/ts/extension.ts'],
    outdir: 'dist',
    target: 'node',
    format: 'cjs',
    naming: 'extension.js',
    ...common,
  },
  {
    entrypoints: ['src/ts/web/extension.ts'],
    outdir: 'dist/web',
    target: 'browser',
    format: 'cjs',
    naming: 'extension.js',
    ...common,
  },
  {
    entrypoints: ['src/ts/server/server.ts'],
    outdir: 'dist',
    target: 'node',
    format: 'cjs',
    naming: 'server.js',
    ...common,
  },
  {
    entrypoints: ['src/ts/server/browserServerMain.ts'],
    outdir: 'dist/web',
    target: 'browser',
    format: 'iife',
    naming: 'server.js',
    ...common,
  },
];

async function buildOnce(): Promise<boolean> {
  const results = await Promise.all(targets.map((config) => Bun.build(config)));
  let ok = true;
  for (const result of results) {
    for (const log of result.logs) {
      console.log(log);
    }
    ok = ok && result.success;
  }
  return ok;
}

async function main(): Promise<void> {
  const success = await buildOnce();
  if (!success) {
    process.exit(1);
  }
  console.log('build complete');

  if (isWatch) {
    let pending = false;
    const rebuild = () => {
      if (pending) return;
      pending = true;
      setTimeout(async () => {
        pending = false;
        console.log('rebuilding...');
        const ok = await buildOnce();
        console.log(ok ? 'build complete' : 'build failed');
        pending = false;
      }, 100);
    };

    // Watch both the TypeScript source and the Zig module sources so a
    // zig build + copy-wasm cycle can be followed by a TS rebuild that
    // picks up the new .wasm files.
    watch('src/ts', { recursive: true }, rebuild);
    watch('src/zig', { recursive: true }, rebuild);
    console.log('[watch] watching src/ts/ and src/zig/src/ for changes...');
  }
}

await main();
