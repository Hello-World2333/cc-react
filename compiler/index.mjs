/**
 * cc-react compiler entry (legacy script interface).
 *
 * Usage: node compiler/index.mjs <entry.tsx> <out.lua>
 *
 * Kept for the repo's npm scripts and programmatic use; the full CLI
 * (flags, --watch, --help, --version) lives in compiler/cli.mjs — the
 * `cc-react` bin target of the published package.
 */
import { compile } from './compile.mjs';

const [entry, outFile] = process.argv.slice(2);
if (!entry || !outFile) {
  console.error('usage: node compiler/index.mjs <entry.tsx> <out.lua>');
  process.exit(1);
}

try {
  await compile(entry, outFile, { log: { success: (m) => console.log(m) } });
} catch (err) {
  console.error(err && err.message ? err.message : String(err));
  process.exit(1);
}
