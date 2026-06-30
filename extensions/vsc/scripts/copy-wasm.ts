import * as path from 'path';
import { readdir, mkdir, copyFile } from 'fs/promises';
import { existsSync } from 'fs';

export async function copyWasm(): Promise<void> {
  // zig-out/ lives in the extension root (next to build.zig).
  const srcRoot = path.join(import.meta.dir, '..', 'zig-out');
  const destDir = path.join(import.meta.dir, '..', 'dist', 'wasm');
  await mkdir(destDir, { recursive: true });

  if (!existsSync(srcRoot)) {
    console.warn(`zig output not found at ${srcRoot} — did "zig build wasm" run?`);
    return;
  }

  async function walk(dir: string): Promise<void> {
    const entries = await readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(full);
      } else if (entry.name.endsWith('.wasm')) {
        await copyFile(full, path.join(destDir, entry.name));
        console.log(`copied ${entry.name}`);
      }
    }
  }

  await walk(srcRoot);
}

if (import.meta.main) {
  await copyWasm();
}
