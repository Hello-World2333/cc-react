/**
 * Fixture: first of TWO files that export a component named `Widget`.
 * esbuild renames the second one (components/extra/Widget) to Widget2 in the
 * bundle — including its JSX tag — so both compile and render independently.
 */

export function Widget({ label }: { label: string }) {
  return <Text>{label}</Text>;
}
