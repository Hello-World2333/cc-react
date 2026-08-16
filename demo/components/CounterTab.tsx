/**
 * Counter tab — the interaction showcase: useState (including functional
 * updates and array spread), useEffect with dependency comparison, conditional
 * rendering (the badge appears at count >= 5), and a scrollable recorded
 * history list. The CounterControls / BigNumberBadge / HistoryList live in
 * their own files (multi-file import).
 */

import { CounterControls } from './CounterControls';
import { BigNumberBadge } from './Badge';
import { HistoryList } from './HistoryList';
import { DIM, FAINT, YELLOW } from '../lib/theme';

export function CounterTab() {
  const [count, setCount] = useState(0);
  const [history, setHistory] = useState<number[]>([]);
  const [lastChange, setLastChange] = useState('count -> 0');

  // Fires only when `count` changes (deps array comparison); the setState
  // inside re-renders with unchanged deps, so it does not loop.
  useEffect(() => {
    setLastChange('count -> ' + count);
  }, [count]);

  return (
    <Box style={{ flexDirection: 'column', alignItems: 'flex-start' }}>
      <Text style={{ fontSize: 1, color: FAINT, marginBottom: 4 }}>state + effects</Text>
      <Text style={{ fontSize: 2, color: YELLOW, marginBottom: 4 }}>Count: {count}</Text>
      <Text style={{ fontSize: 1, color: DIM, marginBottom: 4 }}>{lastChange}</Text>

      <CounterControls
        onDecrement={() => setCount(count - 1)}
        onIncrement={() => setCount(count + 1)}
        onReset={() => setCount(0)}
        onRecord={() => setHistory([...history, count])}
      />

      {count >= 5 ? <BigNumberBadge /> : null}

      <HistoryList history={history} height={48} />
    </Box>
  );
}
