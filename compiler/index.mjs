/**
 * cc-react compiler entry.
 *
 * Pipeline (docs/architecture.md §5):
 *   1. esbuild BUNDLES the whole app (entry + imports across multiple .tsx /
 *      .ts files), strips TypeScript types and preserves JSX — the app may be
 *      split across files with import/export, exactly like a normal React app
 *   2. @babel/parser builds a JSX AST of the single bundled chunk
 *   3. codegen.mjs lowers the AST to Lua (style-tree construction code)
 *   4. the framework runtime (runtime/runtime.lua) is embedded verbatim and
 *      the chunk ends with `return ccreact` — the output is a MODULE whose
 *      start(side) is a simpleParallel task (the main program composes it)
 *
 * Multi-file imports are resolved at compile time (bundling): the Lua output
 * stays a SINGLE module, so deployment is unchanged (copy ui.lua). Name
 * collisions between files are resolved by esbuild (identifiers are renamed
 * consistently, including JSX tags), and only the entry's exports survive as
 * `export { ... }` statements, which codegen.mjs ignores.
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

// Bundle the app: resolve every import/export across the source files into a
// single chunk (jsx: 'preserve' keeps JSX syntax for codegen; .ts/.tsx are
// esbuild's default loaders). The bundled chunk has no import statements
// left — only the entry's own exports may survive as `export { ... }`.
let bundled;
try {
  const res = await esbuild.build({
    entryPoints: [entry],
    bundle: true,
    write: false,
    jsx: 'preserve',
    format: 'esm',
    target: 'es2020',
  });
  bundled = res.outputFiles[0].text;
} catch (err) {
  console.error('cc-react: bundling failed:');
  for (const e of err.errors || []) {
    console.error('  ' + (e.text || String(e)));
  }
  process.exit(1);
}

const ast = parse(bundled, { sourceType: 'module', plugins: ['jsx'] });

// ---- collect component names (functions whose body contains JSX) ----
// Async functions are never components (they can't render synchronously);
// they're collected separately so render(<AsyncApp/>) gives a clear error.
const components = [];
const asyncComponents = [];
const collectFn = (node) => {
  if (node && node.id && node.id.name && containsJsx(node)) {
    if (node.async) asyncComponents.push(node.id.name);
    else components.push(node.id.name);
  }
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
        if (d.init.async) asyncComponents.push(d.id.name);
        else components.push(d.id.name);
      }
    }
  }
}

const codegen = new Codegen(components, asyncComponents);
const compiled = codegen.generateProgram(ast);

const runtime = fs.readFileSync(path.join(__dirname, '..', 'runtime', 'runtime.lua'), 'utf8');
const banner = [
  '--[[',
  '  cc-react build',
  `  entry : ${entry}`,
  `  time  : ${new Date().toISOString()}`,
  '  This file is a MODULE, not a standalone program. Deploy it into a CC:',
  '  Tweaked computer (e.g. as ui.lua) and drive it from your main program:',
  '    local simpleParallel = require("lib.simpleParallel")',
  '    local ui = require("ui")',
  '    simpleParallel.add(function() ui.start("left") end)   -- GPU side',
  '    simpleParallel.start()                                -- + network tasks',
  ']]',
].join('\n');

const output = `${banner}\n\n${runtime}\n\n-- ===== compiled from ${entry} =====\n\n${compiled}\n\n`
  + `-- ===== module interface (simpleParallel task + debug hooks) =====\nreturn ccreact\n`;
fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, output);
console.log(`compiled ${entry} -> ${outFile} (${output.length} bytes)`);
