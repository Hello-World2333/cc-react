/**
 * Demo helpers — pure functions imported from a plain .ts module.
 *
 * `plural` is imported with an ALIAS at the call site
 * (import { plural as countWord } — see components/ScrollTab.tsx), which the
 * bundler resolves consistently. These compile to plain Lua functions.
 */

/** "1 click" / "2 clicks" — trivial pluralization. */
export function plural(n: number, word: string): string {
  return n === 1 ? '1 ' + word : n + ' ' + word + 's';
}

/** Zero-pad small numbers: pad2(8) -> "08". */
export function pad2(n: number): string {
  return n < 10 ? '0' + n : String(n);
}

/**
 * Keep displayed error strings short enough to fit a 192px screen line
 * (~29 chars at fontSize 1). Real network errors ("connection refused",
 * "dns lookup failed") pass through; long developer errors (e.g. the
 * "http client not set: ..." message) collapse to a generic label.
 */
export function shortError(e: string): string {
  return e.length > 24 ? 'network error' : e;
}
