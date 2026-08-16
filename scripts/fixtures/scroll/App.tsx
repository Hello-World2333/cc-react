/**
 * Scroll fixture — exercises the <Scroll> viewport in isolation.
 *
 * Root panel → <Scroll height=120 width='100%'> containing:
 *   - 14 numbered rows (vertical overflow: content ~200px > 120px viewport)
 *   - one long row (horizontal overflow → sub-range clipping)
 *   - a "Bottom" button as the last item (click-through after scrolling)
 *
 * The scroll sits high on screen (top ~27px), so rows below its fold are
 * still on-screen — letting the headless test assert pixel-level clipping.
 */

const LONG_ROW =
  'This row is much longer than the viewport and must be clipped horizontally';

function App() {
  const [clicks, setClicks] = useState(0);

  return (
    <Panel
      style={{
        width: '100%',
        height: '100%',
        backgroundColor: '#131318',
        padding: 10,
        flexDirection: 'column',
      }}
    >
      <Text style={{ fontSize: 1, color: '#8a8a95' }}>clicks: {clicks}</Text>
      <Scroll
        style={{
          width: '100%',
          height: 120,
          flexDirection: 'column',
          gap: 4,
          marginTop: 8,
        }}
      >
        {[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14].map((i) => (
          <Text style={{ color: '#7ec8ff' }}>row {i}</Text>
        ))}
        <Text style={{ color: '#ffd866' }}>{LONG_ROW}</Text>
        <Button label="Bottom" onClick={() => setClicks(clicks + 1)} />
      </Scroll>
    </Panel>
  );
}

render(<App />);
