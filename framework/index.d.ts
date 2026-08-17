/**
 * Global types for the cc-react framework runtime.
 *
 * The framework is NOT imported: `useState` / `useEffect` / `render` and the
 * Box / Panel / Text / Button / Scroll / Input components are globals provided
 * by the Lua runtime embedded in the compiled module. The compiler maps these
 * names onto the runtime's hook/entry machinery and node factories.
 *
 * Usage — add to your tsconfig.json:
 *   "types": ["@linyun-host/cc-react/framework"]
 *
 * This makes all globals (hooks, components, JSX namespace) available in your
 * .tsx files without any import statements. For referencing prop types in your
 * own code (e.g. wrapper components), use the named exports:
 *
 *   import type { Style, BoxProps, InputProps } from '@linyun-host/cc-react/framework';
 *
 * The compiled output is a MODULE: the top-level `render(<App/>)` only mounts
 * the root component (__mount); the module returns a table whose `start(side)`
 * is a simpleParallel task — the main program composes it, e.g.
 *   local ui = require("ui")
 *   simpleParallel.add(function() ui.start("left") end)
 *   simpleParallel.start()
 *
 * `React` is declared only so TS's classic JSX mode type-checks capitalized
 * tags (`<Panel/>` → React.createElement(Panel, ...)); it never reaches the
 * compiled output.
 */

// ---------------------------------------------------------------------------
// All global declarations live inside `declare global` so that the file can
// both (a) act as a module with named exports AND (b) inject globals into
// every .tsx file that includes this type root.
// ---------------------------------------------------------------------------

declare global {
  // ----- React shim (classic JSX transform only) -----

  /** @internal Shim for classic JSX transform (`"jsx": "react"`). */
  // eslint-disable-next-line no-var
  var React: {
    createElement: (type: unknown, props: unknown, ...children: unknown[]) => JSX.Element;
  };

  // ----- Hooks -----

  /**
   * Create a stateful value. Returns `[value, setValue]`.
   *
   * `setValue` accepts a new value or an updater function `(prev) => next`.
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

  // ----- Network (async/await + fetch) -----

  /**
   * A runtime "future" — an async operation the UI can `await`. Typed as
   * PromiseLike so TypeScript unwraps `await` to the response type; the Lua
   * runtime resolves it via an event-driven continuation (no native promise /
   * coroutine).
   */
  type Future<T> = PromiseLike<T>;

  /** Options for `fetch`. */
  interface FetchOptions {
    method?: 'GET' | 'POST' | 'PUT' | 'DELETE' | string;
    headers?: Record<string, string>;
    /** A plain object body is JSON-encoded and sent as `application/json`. */
    body?: string | Record<string, unknown>;
  }

  /**
   * HTTP response (docs/lib http client).
   *
   * - `ok` is `true` for 2xx status codes.
   * - Failures (network error / DNS / timeout / client not configured) resolve
   *   with `{ ok: false, error: <message> }` so you can branch on `resp.ok`
   *   without try/catch (v1 does not compile await try/catch).
   */
  interface Response {
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
  interface RequestState<T> {
    data: T | null;
    loading: boolean;
    error: string | null;
    /** Re-run the fetcher immediately (even when deps are unchanged). */
    refetch: () => void;
  }

  /**
   * Fetch data from the network. Runs in the background (the networkLoop
   * task, composed by the main program) so the UI never blocks; returns a
   * future to `await`.
   *
   * ```tsx
   * async function load() {
   *   const resp = await fetch('http://192.168.1.50:8080/hello');
   *   if (resp.ok) setData(resp.body); else setError(resp.error);
   * }
   * ```
   */
  // eslint-disable-next-line no-var
  var fetch: (url: string, options?: FetchOptions) => Future<Response>;

  /**
   * Data-fetch hook with loading / data / error states. Fetches on mount and
   * whenever `deps` change; stale responses (an older request resolving after
   * a newer one started) are discarded. `fetcher` must return a future.
   *
   * ```tsx
   * const req = useRequest(() => fetch(URL));
   * // req.loading / req.data / req.error / req.refetch()
   * ```
   */
  // eslint-disable-next-line no-var
  var useRequest: <T = Response>(
    fetcher: () => Future<T>,
    deps?: readonly unknown[],
  ) => RequestState<T>;

  // ----- Components (global) -----

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
     * Colors accept `"#rgb"`, `"#rrggbb"`, or `"#aarrggbb"` — they are
     * compiled to ARGB numbers at build time.
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
      /** Background painted behind text glyphs (drawText bg; nil = none). */
      textBackgroundColor?: string;
      fontSize?: number;
      borderColor?: string;
      /** Pressed background for buttons (needs tm_monitor_mouse_click/up). */
      pressedColor?: string;
      /** Focus ring border color for focused inputs. */
      focusBorderColor?: string;
      /** Input text color while the value is empty (placeholder shown). */
      placeholderColor?: string;
      /** Input cursor (insertion point) color. */
      cursorColor?: string;
      /** Scroll only: px per mouse-wheel notch (default 8 = one 5×8 row). */
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
      children?: string | number;
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
     * Text input (controlled). The value lives in the app's `useState` and is
     * updated via `onChange`. Built-in editing: character insert at cursor,
     * Backspace / Delete / arrows / Home / End, Enter fires `onSubmit`,
     * Tab / Shift+Tab cycles focus. Clicking places the cursor at the click.
     *
     * `onKey` raw key codes are GLFW codes (Tom's Peripherals keyboard passes
     * Minecraft key codes through): Enter 257, Tab 258, Backspace 259,
     * Delete 261, Left 263, Right 262, Home 268, End 269, Shift 340/344.
     */
    interface InputProps {
      style?: Style;
      value?: string;
      placeholder?: string;
      onChange?: (value: string) => void;
      onSubmit?: () => void;
      /** Raw key hook — `isUp` is `false` on press/repeat, `true` on release. */
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
// Named exports — so users can reference prop types in wrapper components:
//   import type { Style, BoxProps, InputProps } from '@linyun-host/cc-react/framework';
// ---------------------------------------------------------------------------

export type Style = globalThis.JSX.Style;
export type BoxProps = globalThis.JSX.BoxProps;
export type TextProps = globalThis.JSX.TextProps;
export type ButtonProps = globalThis.JSX.ButtonProps;
export type ScrollProps = globalThis.JSX.ScrollProps;
export type InputProps = globalThis.JSX.InputProps;
export type { Future, FetchOptions, Response, RequestState };
