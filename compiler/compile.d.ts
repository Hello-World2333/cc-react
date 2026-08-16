/**
 * Type declarations for cc-react's programmatic compile API.
 *
 * The primary interface is the CLI (`cc-react` bin); these types cover the
 * same pipeline for embedding cc-react in build scripts / other tooling.
 * The compile-time pipeline: esbuild bundle → JSX AST → Lua codegen →
 * embed runtime/runtime.lua → write a single module whose start(side) is a
 * simpleParallel task.
 */

/** Path of the framework Lua runtime embedded into every compiled module. */
export const RUNTIME_PATH: string;

/** Fatal compile failure (bundling / codegen / I/O). `message` is user-facing. */
export class CompileError extends Error {}

/** esbuild options for bundling a cc-react app (entry + all imports). */
export function buildOptions(entry: string): Record<string, unknown>;

/** Format esbuild's error list (from a thrown build error) as one string. */
export function formatBundleErrors(errors: readonly unknown[] | undefined): string;

export interface CompileResult {
  outFile: string;
  /** Size of the emitted Lua module in bytes. */
  bytes: number;
}

export interface CompileLogger {
  success(message: string): void;
}

/**
 * Assemble the final Lua module from an esbuild-bundled JS chunk:
 * parse → component collection → codegen → embed runtime + banner.
 * Throws CompileError / codegen errors on bad input.
 */
export function assemble(bundledText: string, entry: string): string;

/**
 * One-shot compile: bundle `entry` (a .tsx file), lower it to Lua, embed the
 * runtime and write the module to `outFile`. Throws CompileError with a
 * user-facing message on any failure.
 */
export function compile(
  entry: string,
  outFile: string,
  options?: { log?: CompileLogger | null },
): Promise<CompileResult>;
