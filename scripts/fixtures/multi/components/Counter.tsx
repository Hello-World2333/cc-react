/**
 * Fixture: a component in its own file that owns LOCAL hook state — proves
 * useState works inside imported component files (state slots are keyed by
 * component instance path + hook index, independent of the source file).
 */

export function Counter() {
  const [n, setN] = useState(0);
  return (
    <Box style={{ flexDirection: 'row', alignItems: 'center', gap: 4 }}>
      <Text>counter: {n}</Text>
      <Button label="up" onClick={() => setN(n + 1)} />
    </Box>
  );
}
