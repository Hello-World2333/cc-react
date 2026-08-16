/**
 * cc-react demo — entry file.
 *
 * Exercises both MVP acceptance criteria (docs/architecture.md §14):
 *   1. static page rendering — styled Box/Text/Button/Panel tree laid out by
 *      the flexbox runtime and drawn to the Tom's Peripherals GPU
 *   2. interaction + dirty-rect loop — button clicks update hooks state,
 *      re-run the component, compare layout trees and repaint only changes
 *
 * Multi-file demo: the UI is split across files (demo/components/*), imported
 * here with normal import/export statements. The compiler BUNDLES them into
 * the single Lua module before codegen, so deployment stays one ui.lua file.
 *
 * The `useState` / `useEffect` / `render` globals are provided by the Lua
 * runtime; the compiler maps them onto its hook/entry machinery.
 */

import { Header } from './components/Header';
import { CounterControls } from './components/CounterControls';
import { BigNumberBadge } from './components/Badge';
import { HistoryList } from './components/HistoryList';

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
      <Header count={count} />

      <CounterControls
        onDecrement={() => setCount(count - 1)}
        onIncrement={() => setCount(count + 1)}
        onReset={() => setCount(0)}
        onRecord={() => setHistory([...history, count])}
      />

      <Text style={{ fontSize: 1, color: '#5a5a66', marginTop: 8 }}>{lastChange}</Text>

      {count >= 5 ? <BigNumberBadge /> : null}

      <HistoryList history={history} />
    </Panel>
  );
}

render(<App />);
