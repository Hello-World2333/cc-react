/**
 * cc-react compiler entry.
 *
 * Pipeline (docs/architecture.md §5):
 *   1. esbuild strips TypeScript types and preserves JSX (single-file apps)
 *   2. @babel/parser builds a JSX AST
 *   3. codegen.mjs lowers the AST to Lua (style-tree construction code)
 *   4. the framework runtime (runtime/runtime.lua) is embedded verbatim,
 *      producing a single self-contained main.lua
 *
 * Usage: node compiler/index.mjs <entry.tsx> <out.lua>
 */
import esbuild from 'esbuild';
import { parse } from '@babel/parser';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Codegen, containsJsx } from './codegen.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const [entry, outFile] = process.argv.slice(2);
if (!entry || !outFile) {
  console.error('usage: node compiler/index.mjs <entry.tsx> <out.lua>');
  process.exit(1);
}

const src = fs.readFileSync(entry, 'utf8');
const res = await esbuild.transform(src, {
  loader: 'tsx',
  jsx: 'preserve',
  target: 'es2020',
  format: 'esm',
});
const ast = parse(res.code, { sourceType: 'module', plugins: ['jsx'] });

// ---- collect component names (functions whose body contains JSX) ----
const components = [];
const collectFn = (node) => {
  if (node && node.id && node.id.name && containsJsx(node)) components.push(node.id.name);
};
for (const stmt of ast.program.body) {
  if (stmt.type === 'FunctionDeclaration') {
    collectFn(stmt);
  } else if ((stmt.type === 'ExportNamedDeclaration' || stmt.type === 'ExportDefaultDeclaration')
      && stmt.declaration) {
    collectFn(stmt.declaration);
  } else if (stmt.type === 'VariableDeclaration') {
    for (const d of stmt.declarations) {
      if (d.id.type === 'Identifier' && d.init
          && (d.init.type === 'ArrowFunctionExpression' || d.init.type === 'FunctionExpression')
          && containsJsx(d.init)) {
        components.push(d.id.name);
      }
    }
  }
}

const codegen = new Codegen(components);
const compiled = codegen.generateProgram(ast);

const runtime = fs.readFileSync(path.join(__dirname, '..', 'runtime', 'runtime.lua'), 'utf8');
const banner = [
  '--[[',
  '  cc-react build',
  `  entry : ${entry}`,
  `  time  : ${new Date().toISOString()}`,
  '  Deploy: copy this file into a CC: Tweaked computer and run `lua main.lua [gpuSide]`.',
  ']]',
].join('\n');

const output = `${banner}\n\n${runtime}\n\n-- ===== compiled from ${entry} =====\n\n${compiled}\n`;
fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, output);
console.log(`compiled ${entry} -> ${outFile} (${output.length} bytes)`);
