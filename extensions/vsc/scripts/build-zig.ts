import * as path from 'path';
import { $ } from 'bun';
import { copyWasm } from './copy-wasm';

// The build.zig for extension WASM modules lives at the extension root
// (extensions/vsc/), not inside src/zig/.
const zigDir = path.join(import.meta.dir, '..');
// Priority: explicit CLI arg > PARAM_OPTIMIZE (forwarded by the root build.zig's
// -Doptimize) > 'ReleaseSmall' default.
const optimize = process.argv[2] ?? process.env.PARAM_OPTIMIZE ?? 'ReleaseSmall';

try {
  await $`zig build wasm -Doptimize=${optimize}`.cwd(zigDir);
} catch (err) {
  console.error('zig build failed — is the Zig toolchain installed and on PATH?');
  throw err;
}

await copyWasm();
