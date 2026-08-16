/**
 * Demo recorded-history list. Receives the history array as a prop and maps
 * it to rows; renders nothing while the list is empty (early return null).
 */

export function HistoryList({ history }: { history: number[] }) {
  if (history.length === 0) return null;
  return (
    <Panel
      style={{
        marginTop: 8,
        padding: 10,
        backgroundColor: '#17171e',
        flexDirection: 'column',
        alignItems: 'center',
      }}
    >
      <Text style={{ color: '#8a8a95', marginBottom: 4 }}>Recorded:</Text>
      {history.map((v) => (
        <Text style={{ color: '#7ec8ff' }}>#{v}</Text>
      ))}
    </Panel>
  );
}
