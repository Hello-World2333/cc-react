/**
 * Demo theme — color constants imported from a plain .ts module (no JSX).
 *
 * These colors are RUNTIME strings: the compiler only folds hex color
 * literals it sees in the SAME file as the JSX, so imported colors reach the
 * runtime as "#rrggbb" strings and the runtime's __color parses them. All
 * three hex formats are represented here: #rgb, #rrggbb, #aarrggbb.
 */

export const BG = '#0e0e12'; // root background
export const PANEL_BG = '#17171e'; // card / panel background
export const TEXT = '#ffffff';
export const ACCENT = '#7ec8ff'; // highlight / focus ring
export const YELLOW = '#ffd866';
export const DIM = '#8a8a95'; // secondary text
export const FAINT = '#5a5a66'; // tertiary text
export const BORDER = '#4a4a5a';
export const BTN_BG = '#2a2a35'; // button background
export const ACTIVE_BG = '#223a4d'; // active tab background
export const RED = '#f80'; // #rgb form
export const GREEN = '#00c853'; // #rrggbb form
export const TRANSLUCENT = '#66ff0000'; // #aarrggbb form (semi-transparent red)
