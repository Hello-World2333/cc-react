/**
 * Demo button row: - / + / Reset / Record.
 *
 * The click handlers are created in App.tsx and passed here as props —
 * functions cross file boundaries like any other value.
 */

export function CounterControls({
  onDecrement,
  onIncrement,
  onReset,
  onRecord,
}: {
  onDecrement: () => void;
  onIncrement: () => void;
  onReset: () => void;
  onRecord: () => void;
}) {
  return (
    <Box style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
      <Button label="-" style={{ width: 40, height: 40, fontSize: 2 }} onClick={onDecrement} />
      <Button label="+" style={{ width: 40, height: 40, fontSize: 2 }} onClick={onIncrement} />
      <Button label="Reset" onClick={onReset} />
      <Button label="Record" onClick={onRecord} />
    </Box>
  );
}
