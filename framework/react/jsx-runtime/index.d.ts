/**
 * cc-react JSX runtime type declarations.
 *
 * Provides the types TypeScript expects from `react/jsx-runtime` when using
 * `"jsx": "react-jsx"`.  This is a TYPE-ONLY shim — the actual JSX transform
 * is handled by cc-react's own compiler, not React.
 *
 * tsconfig.json should include:
 *   "compilerOptions": {
 *     "jsx": "react-jsx",
 *     "paths": { "react/jsx-runtime": ["./node_modules/@linyun-host/cc-react/framework/react/jsx-runtime"] }
 *   }
 */

// ---------------------------------------------------------------------------
// JSX namespace — consumed by TypeScript's jsx-jsx check.
// ---------------------------------------------------------------------------

export namespace JSX {
  interface Element {}

  interface Style {
    flexDirection?: 'row' | 'column';
    justifyContent?: 'flex-start' | 'center' | 'flex-end' | 'space-between' | 'space-around';
    alignItems?: 'flex-start' | 'center' | 'flex-end' | 'stretch';
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
    disabled?: boolean;
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
    disabled?: boolean;
  }

  interface ScrollProps {
    style?: Style;
    children?: Element | Element[] | null | false;
    onClick?: () => void;
    onMouseDown?: () => void;
    onMouseUp?: () => void;
    disabled?: boolean;
  }

  interface InputProps {
    style?: Style;
    value?: string;
    placeholder?: string;
    onChange?: (value: string) => void;
    onSubmit?: () => void;
    onKey?: (key: number, isUp: boolean) => void;
    disabled?: boolean;
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

// ---------------------------------------------------------------------------
// Runtime function stubs (type-only — never emitted to Lua).
// ---------------------------------------------------------------------------

/** @internal Called by the JSX transform for single-child elements. */
export function jsx(
  type: unknown,
  props: Record<string, unknown>,
  key?: string | number,
): JSX.Element;

/** @internal Called by the JSX transform for static-child elements. */
export function jsxs(
  type: unknown,
  props: Record<string, unknown>,
  key?: string | number,
): JSX.Element;

/** @internal Fragment (unused by cc-react, required by the transform). */
export const Fragment: unique symbol;
