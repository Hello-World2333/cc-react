/**
 * Global types for the cc-react framework runtime.
 *
 * The framework is NOT imported: `useState` / `useEffect` / `render` and the
 * Box / Panel / Text / Button components are globals provided by the Lua
 * runtime embedded in the compiled module. The compiler maps these names
 * onto the runtime's hook/entry machinery and node factories.
 *
 * The compiled output is a MODULE: the top-level `render(<App/>)` only mounts
 * the root component (__mount); the module returns a table whose `start(side)`
 * is a simpleParallel task — the main program composes it, e.g.
 * `simpleParallel.add(function() ui.start("left") end)`, so the UI loop runs
 * non-blockingly alongside future network tasks.
 *
 * `React` is declared only so TS's classic JSX mode type-checks capitalized
 * tags (`<Panel/>` → React.createElement(Panel, ...)); it never reaches the
 * compiled output.
 */

// eslint-disable-next-line no-var
declare var React: {
  createElement: (type: unknown, props: unknown, ...children: unknown[]) => JSX.Element;
};

// eslint-disable-next-line no-var
declare var useState: <T>(initial: T) => [T, (value: T | ((prev: T) => T)) => void];
// eslint-disable-next-line no-var
declare var useEffect: (effect: () => void, deps?: readonly unknown[]) => void;
// eslint-disable-next-line no-var
declare var render: (element: JSX.Element) => void;

/**
 * A runtime "future" — an async operation the UI can `await`. Typed as
 * PromiseLike only so TypeScript unwraps `await` to the response type; the
 * Lua runtime resolves it via an event-driven continuation (no native
 * promise / coroutine).
 */
type Future<T> = PromiseLike<T>;

interface FetchOptions {
  method?: 'GET' | 'POST' | 'PUT' | 'DELETE' | string;
  headers?: Record<string, string>;
  /** A plain object body is JSON-encoded and sent as application/json. */
  body?: string | Record<string, unknown>;
}

/**
 * HTTP response (docs/lib http client). `ok` is true for 2xx; failures
 * (network error / DNS / timeout / not configured) resolve with
 * `{ ok: false, error: <message> }` so `await` code can branch on resp.ok
 * without try/catch (await try/catch is not compiled yet).
 */
interface Response {
  ok: boolean;
  status?: number;
  statusText?: string;
  headers?: Record<string, string>;
  body?: string;
  error?: string;
  text(): string;
  json(): any;
}

/** Three-state data-fetch hook state. `data` is the resolved response. */
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
 * future to `await`:
 *
 *   async function load() {
 *     const resp = await fetch('http://192.168.1.50:8080/hello');
 *     if (resp.ok) setData(resp.body); else setError(resp.error);
 *   }
 */
// eslint-disable-next-line no-var
declare var fetch: (url: string, options?: FetchOptions) => Future<Response>;

/**
 * Data-fetch hook with loading/data/error states. Fetches on mount and
 * whenever deps change; stale responses (an older request resolving after a
 * newer one started) are ignored. `fetcher` must return a future:
 *
 *   const req = useRequest(() => fetch(URL));
 *   // req.loading / req.data / req.error / req.refetch()
 */
// eslint-disable-next-line no-var
declare var useRequest: <T = Response>(
  fetcher: () => Future<T>,
  deps?: readonly unknown[],
) => RequestState<T>;

declare var Box: (props: JSX.BoxProps) => JSX.Element;
declare var Panel: (props: JSX.BoxProps) => JSX.Element;
declare var Text: (props: JSX.TextProps) => JSX.Element;
declare var Button: (props: JSX.ButtonProps) => JSX.Element;
declare var Scroll: (props: JSX.ScrollProps) => JSX.Element;
declare var Input: (props: JSX.InputProps) => JSX.Element;

declare namespace JSX {
  interface Element {}

  /** Common layout/style surface understood by the flexbox runtime. */
  interface Style {
    flexDirection?: 'row' | 'column';
    justifyContent?: 'flex-start' | 'center' | 'flex-end' | 'space-between' | 'space-around';
    alignItems?: 'flex-start' | 'center' | 'flex-end' | 'stretch';
    /** px, or "100%" of the parent content box (width only). */
    width?: number | '100%';
    height?: number | '100%';
    gap?: number;
    margin?: number | { top?: number; right?: number; bottom?: number; left?: number };
    marginTop?: number;
    marginRight?: number;
    marginBottom?: number;
    marginLeft?: number;
    padding?: number | { top?: number; right?: number; bottom?: number; left?: number };
    /** "#rgb" / "#rrggbb" / "#aarrggbb" — compiled to ARGB numbers. */
    backgroundColor?: string;
    color?: string;
    /** Background painted behind text glyphs (drawText bg; nil = none). */
    textBackgroundColor?: string;
    fontSize?: number;
    borderColor?: string;
    /** Pressed background for buttons (needs tm_monitor_mouse_click/up). */
    pressedColor?: string;
    /** Focus ring border for focused inputs. */
    focusBorderColor?: string;
    /** Input text color while the value is empty (placeholder shown). */
    placeholderColor?: string;
    /** Input cursor (insertion point) color. */
    cursorColor?: string;
    /** Scroll only: px per mouse-wheel notch (default 8 = one 5x8 row). */
    scrollStep?: number;
  }

  interface BoxProps {
    style?: Style;
    children?: JSX.Element | JSX.Element[] | null | false;
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
    children?: JSX.Element | JSX.Element[] | null | false;
    onClick?: () => void;
    onMouseDown?: () => void;
    onMouseUp?: () => void;
  }

  /**
   * Text input (keyboard milestone). The value is CONTROLLED: the app owns
   * the string and updates it via onChange (React style). Built-in editing:
   * characters insert at the cursor, Backspace/Delete/arrows/Home/End move
   * it, Enter fires onSubmit, Tab/Shift+Tab move focus to the next/previous
   * input. Clicking the input focuses it and places the cursor at the click.
   *
   * Key codes in onKey are GLFW codes (Tom's Peripherals keyboard passes
   * Minecraft's key codes through verbatim): Enter 257, Tab 258, Backspace
   * 259, Delete 261, Left 263, Right 262, Home 268, End 269, Shift 340/344.
   */
  interface InputProps {
    style?: Style;
    value?: string;
    placeholder?: string;
    onChange?: (value: string) => void;
    onSubmit?: () => void;
    /** Raw key hook, called after built-in editing (isUp=false on press /
     *  repeat, true on release from tm_keyboard_key_up). */
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
