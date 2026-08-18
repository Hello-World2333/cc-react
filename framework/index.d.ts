/**
 * Global types for the cc-react framework runtime.
 *
 * The framework is NOT imported: `useState` / `useEffect` / `render` and the
 * Box / Panel / Text / Button / Scroll / Input components are globals provided
 * by the Lua runtime embedded in the compiled module.
 *
 * Setup — in your tsconfig.json:
 *   "compilerOptions": {
 *     "jsx": "react-jsx",                           // ← 必须用 react-jsx
 *     "types": ["@linyun-host/cc-react/framework"]
 *   }
 *
 * With `"jsx": "react-jsx"`, TypeScript resolves JSX without requiring a
 * global `React` variable — no conflict with `@types/react` or DOM libs.
 *
 * For referencing prop types in wrapper components, use named exports:
 *   import type { Style, BoxProps, InputProps } from '@linyun-host/cc-react/framework';
 *
 * `React` is NOT declared here. If your project also uses React, install
 * `@types/react` normally — cc-react types are fully compatible.
 */

// ---------------------------------------------------------------------------
// Module-level type declarations (NOT global).
//
// These live outside `declare global` so they do NOT merge with DOM built-in
// types (lib.dom.d.ts).  Users with `@types/react` or DOM libs loaded will
// not see "重复的标识符" or "所有声明必须具有相同的修饰符" errors.
// ---------------------------------------------------------------------------

/** Options for the cc-react `fetch`. */
interface FetchOptions {
  method?: 'GET' | 'POST' | 'PUT' | 'DELETE' | string;
  headers?: Record<string, string>;
  /** A plain object body is JSON-encoded and sent as `application/json`. */
  body?: string | Record<string, unknown>;
}

/**
 * cc-react HTTP response (docs/lib http client).
 *
 * Named `FetchResponse` to avoid merging with the DOM `Response` type.
 * - `ok` is `true` for 2xx status codes.
 * - Failures resolve with `{ ok: false, error: <message> }`.
 */
interface FetchResponse {
  ok: boolean;
  status?: number;
  statusText?: string;
  headers?: Record<string, string>;
  body?: string;
  error?: string;
  /** Read the response body as a plain string. */
  text(): string;
  /** Parse the response body as JSON. */
  json(): any;
}

/** Three-state data-fetch hook state. */
interface FetchRequestState<T> {
  data: T | null;
  loading: boolean;
  error: string | null;
  /** Re-run the fetcher immediately (even when deps are unchanged). */
  refetch: () => void;
}

// ---------------------------------------------------------------------------
// Global declarations — hooks, components, JSX namespace.
//
// Wrapped in `declare global` so they are visible in every .tsx file when
// this file is included via `"types": ["@linyun-host/cc-react/framework"]`.
// ---------------------------------------------------------------------------

declare global {
  // ----- Hooks -----

  /**
   * Create a stateful value. Returns `[value, setValue]`.
   *
   * ```tsx
   * const [count, setCount] = useState(0);
   * setCount(count + 1);          // direct value
   * setCount(prev => prev + 1);   // functional update
   * ```
   */
  // eslint-disable-next-line no-var
  var useState: <T>(initial: T) => [T, (value: T | ((prev: T) => T)) => void];

  /**
   * Run a side-effect when dependencies change.
   *
   * ```tsx
   * useEffect(() => { print(count); }, [count]);
   * ```
   */
  // eslint-disable-next-line no-var
  var useEffect: (effect: () => void, deps?: readonly unknown[]) => void;

  /**
   * Mount the root component. Call once at the top level of your entry .tsx.
   *
   * ```tsx
   * render(<App />);
   * ```
   */
  // eslint-disable-next-line no-var
  var render: (element: JSX.Element) => void;

  // ----- Network -----

  /**
   * Fetch data from the network. Returns a future to `await`.
   *
   * ```tsx
   * async function load() {
   *   const resp = await fetch('http://192.168.1.50:8080/hello');
   *   if (resp.ok) setData(resp.body); else setError(resp.error);
   * }
   * ```
   */
  // eslint-disable-next-line no-var
  var fetch: (url: string, options?: FetchOptions) => PromiseLike<FetchResponse>;

  /**
   * Data-fetch hook with loading / data / error states.
   *
   * ```tsx
   * const req = useRequest(() => fetch(URL));
   * // req.loading / req.data / req.error / req.refetch()
   * ```
   */
  // eslint-disable-next-line no-var
  var useRequest: <T = FetchResponse>(
    fetcher: () => PromiseLike<T>,
    deps?: readonly unknown[],
  ) => FetchRequestState<T>;

  // ----- Timers -----

  /**
   * Run a callback after a delay (milliseconds). Returns a numeric id
   * that can be passed to `clearTimeout` to cancel it.
   *
   * ```tsx
   * const id = setTimeout(() => print('hello'), 1000);
   * clearTimeout(id); // cancel
   * ```
   */
  // eslint-disable-next-line no-var
  var setTimeout: (callback: () => void, ms: number) => number;

  /**
   * Run a callback repeatedly at an interval (milliseconds). Returns a
   * numeric id that can be passed to `clearInterval` to cancel it.
   *
   * ```tsx
   * const id = setInterval(() => print('tick'), 500);
   * clearInterval(id); // cancel
   * ```
   */
  // eslint-disable-next-line no-var
  var setInterval: (callback: () => void, ms: number) => number;

  /** Cancel a pending `setTimeout`. */
  // eslint-disable-next-line no-var
  var clearTimeout: (id: number) => void;

  /** Cancel a pending `setInterval`. */
  // eslint-disable-next-line no-var
  var clearInterval: (id: number) => void;

  // ----- Components -----

  var Box: (props: BoxProps) => JSX.Element;
  var Panel: (props: BoxProps) => JSX.Element;
  var Text: (props: TextProps) => JSX.Element;
  var Button: (props: ButtonProps) => JSX.Element;
  var Scroll: (props: ScrollProps) => JSX.Element;
  var Input: (props: InputProps) => JSX.Element;

  // ----- JSX namespace -----

  namespace JSX {
    interface Element {}

    /**
     * Common layout / style surface understood by the flexbox runtime.
     *
     * Colors: `"#rgb"` / `"#rrggbb"` / `"#aarrggbb"` — compiled to ARGB.
     */
    interface Style {
      flexDirection?: 'row' | 'column';
      justifyContent?: 'flex-start' | 'center' | 'flex-end' | 'space-between' | 'space-around';
      alignItems?: 'flex-start' | 'center' | 'flex-end' | 'stretch';
      /** Fixed px, or `"100%"` of the parent content box (width only). */
      width?: number | '100%';
      height?: number | '100%';
      gap?: number;
      margin?: number | { top?: number; right?: number; bottom?: number; left?: number };
      marginTop?: number;
      marginRight?: number;
      marginBottom?: number;
      marginLeft?: number;
      padding?: number | { top?: number; right?: number; bottom?: number; left?: number };
      backgroundColor?: string;
      color?: string;
      textBackgroundColor?: string;
      fontSize?: number;
      borderColor?: string;
      pressedColor?: string;
      focusBorderColor?: string;
      placeholderColor?: string;
      cursorColor?: string;
      scrollStep?: number;
    }

    interface BoxProps {
      style?: Style;
      children?: Element | Element[] | null | false;
      onClick?: () => void;
      onMouseDown?: () => void;
      onMouseUp?: () => void;
    }

    interface TextProps {
      style?: Style;
      children?: string | number | (string | number)[];
    }

    interface ButtonProps {
      style?: Style;
      label?: string;
      children?: never;
      onClick?: () => void;
      onMouseDown?: () => void;
      onMouseUp?: () => void;
    }

    interface ScrollProps {
      style?: Style;
      children?: Element | Element[] | null | false;
      onClick?: () => void;
      onMouseDown?: () => void;
      onMouseUp?: () => void;
    }

    /**
     * Text input (controlled). Built-in editing: insert / Backspace / Delete
     * / arrows / Home / End / Enter(onSubmit) / Tab(focus cycle).
     *
     * Key codes (GLFW): Enter 257, Tab 258, Backspace 259, Delete 261,
     * Left 263, Right 262, Home 268, End 269, Shift 340/344.
     */
    interface InputProps {
      style?: Style;
      value?: string;
      placeholder?: string;
      onChange?: (value: string) => void;
      onSubmit?: () => void;
      onKey?: (key: number, isUp: boolean) => void;
    }

    interface IntrinsicElements {
      box: BoxProps;
      Box: BoxProps;
      panel: BoxProps;
      Panel: BoxProps;
      text: TextProps;
      Text: TextProps;
      button: ButtonProps;
      Button: ButtonProps;
      scroll: ScrollProps;
      Scroll: ScrollProps;
      input: InputProps;
      Input: InputProps;
    }
  }
}

// ---------------------------------------------------------------------------
// Named exports — for wrapper components:
//   import type { Style, BoxProps, FetchResponse } from '@linyun-host/cc-react/framework';
// ---------------------------------------------------------------------------

export type Style = globalThis.JSX.Style;
export type BoxProps = globalThis.JSX.BoxProps;
export type TextProps = globalThis.JSX.TextProps;
export type ButtonProps = globalThis.JSX.ButtonProps;
export type ScrollProps = globalThis.JSX.ScrollProps;
export type InputProps = globalThis.JSX.InputProps;
export type { FetchOptions, FetchResponse, FetchRequestState };
