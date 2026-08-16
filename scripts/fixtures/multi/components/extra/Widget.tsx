/**
 * Fixture: the collision twin of components/Widget.tsx. Both files export a
 * top-level component named `Widget`; the bundler renames this one (its
 * import site aliases it as ExtraWidget), which must stay consistent with the
 * JSX tag so codegen maps it to the right render function.
 */

export function Widget({ label }: { label: string }) {
  return <Text>extra:{label}</Text>;
}
