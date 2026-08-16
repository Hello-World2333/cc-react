/**
 * Demo recorded-history list. Receives the history array as a prop and maps
 * it to rows; renders nothing while the list is empty (early return null).
 *
 * The rows live inside a <Scroll> viewport: once the list grows taller than
 * `height: 96`, the overflow is clipped and can be scrolled with the mouse
 * wheel (tm_monitor_mouse_scroll) or by touch-dragging the list.
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
      <Scroll
        style={{
          width: '100%',
          height: 96,
          flexDirection: 'column',
          alignItems: 'center',
          gap: 4,
        }}
      >
        {history.map((v) => (
          <Text style={{ color: '#7ec8ff' }}>#{v}</Text>
        ))}
      </Scroll>
    </Panel>
  );
}
