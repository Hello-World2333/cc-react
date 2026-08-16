#!/usr/bin/env node
/**
 * cc-react CLI — compile a .tsx app into a single Lua module for CC: Tweaked.
 *
 *   cc-react <entry.tsx> [out.lua] [options]
 *
 * The compiler pipeline lives in compile.mjs; this file is only the
 * user-facing wrapper: argument parsing, --help/--version, error reporting
 * with proper exit codes, and --watch (esbuild context + onEnd rebuilds).
 */
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import esbuild from 'esbuild';
import {
  CompileError,
  assemble,
  buildOptions,
  compile,
  formatBundleErrors,
} from './compile.mjs';

const require = createRequire(import.meta.url);
const pkg = require('../package.json');

const HELP = `cc-react — compile a .tsx app into a single Lua module for CC: Tweaked

Usage:
  cc-react <entry.tsx> [out.lua] [options]

Arguments:
  entry                   entry .tsx file (imports across .tsx/.ts files are
                          bundled at compile time)
  out                     output Lua module (default: dist/ui.lua)

Options:
  -o, --out <file>        output Lua module (same as the positional <out>)
  -w, --watch             rebuild automatically when source files change
  -h, --help              show this help
  -v, --version           print the version

Examples:
  cc-react src/App.tsx dist/ui.lua
  cc-react src/App.tsx --out build/ui.lua --watch

The output is a MODULE: require it from your main program and run it as a
simpleParallel task, e.g.
  local ui = require("ui")
  simpleParallel.add(function() ui.start("left") end)
`;

class UsageError extends Error {}

/**
 * Parse argv (without node/script) into { entry, out, watch }.
 * Throws UsageError on unknown flags / conflicting output paths.
 */
function parseArgs(argv) {
  const args = { entry: null, out: null, watch: false, help: false, version: false };
  const positionals = [];
  let endOfFlags = false;

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (endOfFlags) {
      positionals.push(a);
    } else if (a === '--') {
      endOfFlags = true;
    } else if (a === '-h' || a === '--help') {
      args.help = true;
    } else if (a === '-v' || a === '--version') {
      args.version = true;
    } else if (a === '-w' || a === '--watch') {
      args.watch = true;
    } else if (a === '-o' || a === '--out') {
      const v = argv[++i];
      if (!v) throw new UsageError(`option ${a} requires a file argument`);
      args.out = v;
    } else if (a.startsWith('--out=')) {
      args.out = a.slice('--out='.length);
    } else if (a.startsWith('-') && a !== '-') {
      throw new UsageError(`unknown option: ${a}`);
    } else {
      positionals.push(a);
    }
  }

  if (positionals.length > 2) {
    throw new UsageError(`too many arguments: ${positionals.slice(2).join(' ')}`);
  }
  args.entry = positionals[0] || null;
  if (positionals[1] !== undefined) {
    if (args.out !== null && args.out !== positionals[1]) {
      throw new UsageError('output file specified twice (positional and --out)');
    }
    args.out = positionals[1];
  }
  return args;
}

function timestamp() {
  return new Date().toLocaleTimeString();
}

/** Format a codegen / compile failure for stderr. */
function formatFailure(err) {
  if (err instanceof CompileError || err.name === 'CodegenError') return err.message;
  return err && err.stack ? err.stack : String(err);
}

/** One-shot compile with the CLI's reporter and exit codes. */
async function runOnce(entry, outFile) {
  try {
    await compile(entry, outFile, {
      log: { success: (m) => console.log(m) },
    });
  } catch (err) {
    console.error(formatFailure(err));
    process.exitCode = 1;
  }
}

/**
 * Watch mode: esbuild watches the whole module graph (entry + every import,
 * anywhere on disk) and rebuilds on change. The output .lua is written by
 * our onEnd hook — it is not part of the module graph, so no rebuild loop.
 */
async function runWatch(entry, outFile) {
  const options = buildOptions(entry);
  options.plugins = [
    {
      name: 'cc-react-watch',
      setup(build) {
        build.onEnd(async (result) => {
          if (result.errors.length > 0) {
            console.error(`[${timestamp()}] ` + formatBundleErrors(result.errors));
            return; // keep watching; next edit retries
          }
          try {
            const lua = assemble(result.outputFiles[0].text, entry);
            fs.mkdirSync(path.dirname(outFile), { recursive: true });
            fs.writeFileSync(outFile, lua);
            console.log(
              `[${timestamp()}] compiled ${path.relative(process.cwd(), entry)}`
              + ` -> ${path.relative(process.cwd(), outFile)} (${lua.length} bytes)`,
            );
          } catch (err) {
            console.error(`[${timestamp()}] ` + formatFailure(err));
          }
        });
      },
    },
  ];

  let ctx;
  try {
    ctx = await esbuild.context(options);
    // watch() starts watching and runs the initial build; the first
    // "compiled" message arrives from onEnd right after we announce
    // "watching" (esbuild only throws for the initial build; later
    // rebuild errors land in result.errors).
    await ctx.watch();
  } catch (err) {
    // entry missing / initial build threw (esbuild only throws for the
    // initial build; later rebuild errors land in result.errors)
    console.error(formatBundleErrors(err.errors || [err]));
    process.exitCode = 1;
    return;
  }

  console.log(`[cc-react] watching ${entry} — press Ctrl+C to stop`);
  const stop = async () => {
    await ctx.dispose();
    process.exit(0);
  };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
  await new Promise(() => {}); // keep the process alive
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error('cc-react: ' + err.message);
    console.error(HELP);
    process.exit(1);
  }

  if (args.help) {
    console.log(HELP);
    return;
  }
  if (args.version) {
    console.log(pkg.version);
    return;
  }
  if (!args.entry) {
    console.error('cc-react: missing entry file (the .tsx app to compile)');
    console.error(HELP);
    process.exit(1);
  }

  const outFile = args.out || 'dist/ui.lua';
  if (args.watch) await runWatch(args.entry, outFile);
  else await runOnce(args.entry, outFile);
}

main();
