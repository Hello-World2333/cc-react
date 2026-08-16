/**
 * Global types for the cc-react framework runtime.
 *
 * The framework is NOT imported: `useState` / `useEffect` / `render` and the
 * Box / Panel / Text / Button components are globals provided by the Lua
 * runtime embedded in the compiled program. The compiler maps these names
 * onto the runtime's hook/entry machinery and node factories.
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

declare var Box: (props: JSX.BoxProps) => JSX.Element;
declare var Panel: (props: JSX.BoxProps) => JSX.Element;
declare var Text: (props: JSX.TextProps) => JSX.Element;
declare var Button: (props: JSX.ButtonProps) => JSX.Element;

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
    fontSize?: number;
    borderColor?: string;
    /** Pressed background for buttons (needs tm_monitor_mouse_click/up). */
    pressedColor?: string;
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

  interface IntrinsicElements {
    box: BoxProps;
    Box: BoxProps;
    panel: BoxProps;
    Panel: BoxProps;
    text: TextProps;
    Text: TextProps;
    button: ButtonProps;
    Button: ButtonProps;
  }
}
