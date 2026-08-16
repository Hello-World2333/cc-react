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

// Network demo (milestone 3): async/await compiles to an event-driven state
// machine — `await fetch(...)` starts a request in the background (the
// networkLoop task) and the rest of the function runs when it resolves. The
// main program configures the IP stack (ui.configureNetwork); without it the
// fetch reports the error on screen instead of crashing.
const DEMO_URL = 'http://192.168.1.4/redstone';

function App() {
  const [count, setCount] = useState(0);
  const [history, setHistory] = useState<number[]>([]);
  const [lastChange, setLastChange] = useState('count -> 0');
  const [name, setName] = useState('');
  const [greeted, setGreeted] = useState(false);
  const [netStatus, setNetStatus] = useState('press fetch');

  // Demonstrates useEffect: fires only when `count` changes, then re-renders
  // through a second setState (deps are unchanged on that re-render, so the
  // effect does not loop).
  useEffect(() => {
    setLastChange('count -> ' + count);
  }, [count]);

  // Async/await demo: the body runs to the first await, then the rest runs
  // as an event-driven continuation when the fetch resolves.
  async function fetchHello() {
    setNetStatus('fetching...');
    const resp = await fetch(DEMO_URL);
    if (resp.ok) {
      const msg = resp.json();
      setNetStatus(msg && msg.msg ? 'hello: ' + msg.msg : 'status ' + resp.status);
    } else {
      setNetStatus('error: ' + (resp.error || ('http ' + resp.status)));
    }
  }

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

      {/* Keyboard input milestone: click to focus, type, Enter submits.
          Tab/Shift+Tab would cycle focus if there were more inputs. */}
      <Input
        value={name}
        onChange={setName}
        placeholder="type your name, press enter"
        style={{ width: '100%', height: 22, marginTop: 6 }}
        onSubmit={() => {
          if (name.length > 0) setGreeted(true);
        }}
      />
      <Text style={{ fontSize: 1, color: '#7ec8ff', marginTop: 2 }}>
        {greeted
          ? 'hello, ' + name + '!'
          : name.length > 0
            ? 'typing: ' + name
            : 'focus the field, type, press enter'}
      </Text>

      {/* Network (milestone 3): async/await + fetch (see demo/main.lua for
          the network stack config) */}
      <Box style={{ flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 4 }}>
        <Button label="Fetch" style={{ width: 56, height: 24 }} onClick={fetchHello} />
        <Text style={{ fontSize: 1, color: '#8a8a95' }}>{netStatus}</Text>
      </Box>

      <Text style={{ fontSize: 1, color: '#5a5a66', marginTop: 4 }}>{lastChange}</Text>

      {count >= 5 ? <BigNumberBadge /> : null}

      <HistoryList history={history} />
    </Panel>
  );
}

render(<App />);
