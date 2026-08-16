/**
 * Fixture: a plain .ts helper module (no JSX). Imported values are inlined by
 * the bundler; ACCENT is a hex color constant that stays a runtime string
 * (the compiler only folds color literals it sees in the same file).
 */

export const ACCENT = '#7ec8ff';
export const MARK = '#fixture';

export function formatLabel(n: number): string {
  return 'label ' + String(n);
}
