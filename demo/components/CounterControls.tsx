/**
 * Demo button row: - / + / Reset / Record.
 *
 * The click handlers are created in CounterTab and passed here as props —
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
    <Box style={{ flexDirection: 'row', alignItems: 'center', gap: 4 }}>
      <Button label="-" style={{ width: 30, height: 24, fontSize: 1, padding: 4 }} onClick={onDecrement} />
      <Button label="+" style={{ width: 30, height: 24, fontSize: 1, padding: 4 }} onClick={onIncrement} />
      <Button label="Reset" style={{ width: 46, height: 24, fontSize: 1, padding: 4 }} onClick={onReset} />
      <Button label="Record" style={{ width: 50, height: 24, fontSize: 1, padding: 4 }} onClick={onRecord} />
    </Box>
  );
}
