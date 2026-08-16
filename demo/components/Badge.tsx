/**
 * Demo "big number!" badge — a small stateless component in its own file,
 * conditionally rendered by App.tsx when count >= 5.
 */

export function BigNumberBadge() {
  return (
    <Panel style={{ marginTop: 8, padding: 8, backgroundColor: '#1c2230' }}>
      <Text style={{ color: '#7ec8ff' }}>big number!</Text>
    </Panel>
  );
}
