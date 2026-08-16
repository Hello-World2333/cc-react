/**
 * cc-react MVP demo.
 *
 * Exercises both MVP acceptance criteria (docs/architecture.md §14):
 *   1. static page rendering — styled Box/Text/Button/Panel tree laid out by
 *      the flexbox runtime and drawn to the Tom's Peripherals GPU
 *   2. interaction + dirty-rect loop — button clicks update hooks state,
 *      re-run the component, compare layout trees and repaint only changes
 *
 * The `useState` / `useEffect` / `render` globals are provided by the Lua
 * runtime; the compiler maps them onto its hook/entry machinery.
 */

function App() {
  const [count, setCount] = useState(0);
  const [history, setHistory] = useState<number[]>([]);
  const [lastChange, setLastChange] = useState('count -> 0');

  // Demonstrates useEffect: fires only when `count` changes, then re-renders
  // through a second setState (deps are unchanged on that re-render, so the
  // effect does not loop).
  useEffect(() => {
    setLastChange('count -> ' + count);
  }, [count]);

  return (
    <Panel
      style={{
        width: '100%',
        height: '100%',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'flex-start',
        backgroundColor: '#131318',
        padding: 10,
      }}
    >
      <Text style={{ fontSize: 3, color: '#ffffff', marginBottom: 4 }}>cc-react</Text>
      <Text style={{ fontSize: 1, color: '#6a6a78', marginBottom: 8 }}>
        React-style UI for CC + Tom's GPU
      </Text>
      <Text style={{ fontSize: 2, color: '#ffd866', marginBottom: 12 }}>Count: {count}</Text>

      <Box style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
        <Button label="-" style={{ width: 40, height: 40, fontSize: 2 }} onClick={() => setCount(count - 1)} />
        <Button label="+" style={{ width: 40, height: 40, fontSize: 2 }} onClick={() => setCount(count + 1)} />
        <Button label="Reset" onClick={() => setCount(0)} />
        <Button label="Record" onClick={() => setHistory([...history, count])} />
      </Box>

      <Text style={{ fontSize: 1, color: '#5a5a66', marginTop: 8 }}>{lastChange}</Text>

      {count >= 5 ? (
        <Panel style={{ marginTop: 8, padding: 8, backgroundColor: '#1c2230' }}>
          <Text style={{ color: '#7ec8ff' }}>big number!</Text>
        </Panel>
      ) : null}

      {history.length > 0 ? (
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
      ) : null}
    </Panel>
  );
}

render(<App />);
