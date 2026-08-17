/**
 * Network fixture — exercises the async/await state-machine compilation and
 * the fetch bridge in isolation (headless test: scripts/test_network.lua).
 *
 * The test stubs the network backend (ui.setNetworkBackend), so no real TCP
 * is involved: fetch() queues a job, the networkLoop task processes it via
 * the backend and queues a completion event, and the UI's await continuation
 * runs — the same flow the real docs/lib HTTP client uses in-game.
 *
 * Behaviors covered:
 *   - async/await compiles to an event-driven state machine: sequential
 *     awaits run in order and their values flow into the continuations
 *   - the error path: a failed request resolves with { ok = false, error }
 *   - `await` on a non-future passes the value through (JS semantics)
 *   - useRequest: fetch on mount, loading/data/error states, refetch,
 *     stale-response protection (an older response cannot clobber a newer one)
 */

const URL_ONE = 'http://1.2.3.4:8080/one';
const URL_TWO = 'http://1.2.3.4:8080/two';
const URL_FAIL = 'http://1.2.3.4:8080/fail';
const URL_REQ = 'http://1.2.3.4:8080/req';

function NetworkDemo() {
  const [a, setA] = useState('');
  const [b, setB] = useState('');
  const [status, setStatus] = useState('idle');
  const [plain, setPlain] = useState('');
  const [count, setCount] = useState(0);

  async function loadBoth() {
    setStatus('start');
    const r1 = await fetch(URL_ONE);
    // json() is a METHOD closure on the docs/lib response — it must survive
    // the worker → event → UI round trip (the runtime stores the response in
    // a shared table; CC events can't carry function values).
    setA(r1.ok ? (r1.json() || '') : 'ERR:' + r1.error);
    const r2 = await fetch(URL_TWO);
    setB(r2.ok ? (r2.body || '') : 'ERR:' + r2.error);
    setStatus('done');
  }

  async function loadFail() {
    setStatus('running');
    const r = await fetch(URL_FAIL);
    setStatus(r.ok ? 'unexpected ok' : 'failed: ' + r.error);
  }

  async function loadPlain() {
    const v = await 42; // awaiting a non-future passes the value through
    setPlain('v=' + v);
  }

  const req = useRequest(() => fetch(URL_REQ));

  return (
    <Panel
      style={{
        width: '100%',
        height: '100%',
        backgroundColor: '#131318',
        padding: 10,
        flexDirection: 'column',
        alignItems: 'flex-start',
      }}
    >
      <Text style={{ color: '#8a8a95' }}>async/await</Text>
      <Text style={{ color: '#7ec8ff' }}>A: {a}</Text>
      <Text style={{ color: '#7ec8ff' }}>B: {b}</Text>
      <Text style={{ color: '#7ec8ff' }}>status: {status}</Text>
      <Text style={{ color: '#7ec8ff' }}>plain: {plain}</Text>
      <Box style={{ flexDirection: 'row', gap: 8, marginTop: 4 }}>
        <Button label="loadBoth" onClick={loadBoth} />
        <Button label="loadFail" onClick={loadFail} />
        <Button label="loadPlain" onClick={loadPlain} />
      </Box>

      <Text style={{ color: '#8a8a95', marginTop: 8 }}>useRequest</Text>
      <Text style={{ color: '#ffd866' }}>req: {req.loading ? 'loading' : req.error ? req.error : req.data ? (req.data.body ?? 'empty') : 'empty'}</Text>
      <Box style={{ flexDirection: 'row', gap: 8, marginTop: 4 }}>
        <Button label="refetch" onClick={req.refetch} style={{ width: 72, height: 24 }} />
        <Button label="count+" onClick={() => setCount(count + 1)} style={{ width: 72, height: 24 }} />
      </Box>
      <Text style={{ color: '#8a8a95', marginTop: 4 }}>count: {count}</Text>
    </Panel>
  );
}

render(<NetworkDemo />);
