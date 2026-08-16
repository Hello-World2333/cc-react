/**
 * cc-react compile pipeline (shared by the CLI and the programmatic API).
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
 */
import esbuild from 'esbuild';
import { parse } from '@babel/parser';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Codegen, containsJsx } from './codegen.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/** Framework Lua runtime, embedded verbatim into every compiled module. */
export const RUNTIME_PATH = path.join(__dirname, '..', 'runtime', 'runtime.lua');

/** Fatal compile failure (bundling / codegen / I/O). `message` is user-facing. */
export class CompileError extends Error {
  constructor(message) {
    super(message);
    this.name = 'CompileError';
  }
}

/**
 * esbuild options for bundling a cc-react app into a single JS chunk.
 * `jsx: 'preserve'` keeps JSX syntax for codegen; .ts/.tsx are esbuild's
 * default loaders. Shared by the one-shot compile and watch mode.
 *
 * The ESM-entry plugin makes the app entry an ES module no matter what the
 * consumer's nearest package.json says: esbuild detects the module format of
 * a syntax-less file from the package.json "type" field, and in a CommonJS
 * project it wraps the entry in a `__commonJS` helper whose comma expression
 * (SequenceExpression) the Lua codegen does not support. Appending an empty
 * `export {}` forces ESM detection; esbuild strips it from the output, so
 * codegen never sees it.
 */
function esmEntryPlugin(entry) {
  const resolvedEntry = path.resolve(entry);
  const loader = resolvedEntry.endsWith('.ts') && !resolvedEntry.endsWith('.tsx')
    ? 'ts'
    : 'tsx';
  return {
    name: 'cc-react-esm-entry',
    setup(build) {
      build.onResolve({ filter: /.*/ }, (args) => {
        if (args.kind === 'entry-point' && path.resolve(args.path) === resolvedEntry) {
          return { path: args.path, namespace: 'ccreact-entry' };
        }
        return null; // everything else: esbuild's normal resolution
      });
      build.onLoad({ filter: /.*/, namespace: 'ccreact-entry' }, (args) => {
        const contents = fs.readFileSync(args.path, 'utf8');
        return {
          contents: contents + '\nexport {};',
          loader,
          resolveDir: path.dirname(args.path),
        };
      });
    },
  };
}

export function buildOptions(entry) {
  return {
    entryPoints: [entry],
    bundle: true,
    write: false,
    jsx: 'preserve',
    format: 'esm',
    target: 'es2020',
    logLevel: 'silent', // we format and print our own error output
    plugins: [esmEntryPlugin(entry)],
  };
}

/** Format esbuild's error list (from a thrown build error) as one string. */
export function formatBundleErrors(errors) {
  const lines = ['cc-react: bundling failed:'];
  for (const e of errors || []) {
    const loc = e.location
      ? `${e.location.file}:${e.location.line}:${e.location.column}: `
      : '';
    lines.push('  ' + loc + (e.text || String(e)));
  }
  return lines.join('\n');
}

/**
 * Assemble the final Lua module from an esbuild-bundled JS chunk:
 * parse → component collection → codegen → embed runtime + banner.
 * Throws CodegenError (from codegen.mjs) or CompileError on bad input.
 */
export function assemble(bundledText, entry) {
  const ast = parse(bundledText, { sourceType: 'module', plugins: ['jsx'] });

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

  const runtime = fs.readFileSync(RUNTIME_PATH, 'utf8');
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

  return `${banner}\n\n${runtime}\n\n-- ===== compiled from ${entry} =====\n\n${compiled}\n\n`
    + `-- ===== module interface (simpleParallel task + debug hooks) =====\nreturn ccreact\n`;
}

/**
 * One-shot compile: bundle `entry` (a .tsx file), lower it to Lua, embed the
 * runtime and write the module to `outFile`. Returns { outFile, bytes }.
 * Throws CompileError with a user-facing message on any failure.
 *
 * `log` is an optional { success(message) } sink; by default nothing is
 * printed (the CLI supplies its own reporter).
 */
export async function compile(entry, outFile, { log = null } = {}) {
  let bundled;
  try {
    const res = await esbuild.build(buildOptions(entry));
    bundled = res.outputFiles[0].text;
  } catch (err) {
    throw new CompileError(formatBundleErrors(err.errors));
  }

  let output;
  try {
    output = assemble(bundled, entry);
  } catch (err) {
    if (err instanceof CompileError) throw err;
    throw new CompileError('codegen failed: ' + (err.message || String(err)));
  }

  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  fs.writeFileSync(outFile, output);
  if (log && typeof log.success === 'function') {
    log.success(`compiled ${entry} -> ${outFile} (${output.length} bytes)`);
  }
  return { outFile, bytes: output.length };
}
