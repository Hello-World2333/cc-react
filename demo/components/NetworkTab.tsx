/**
 * Network tab — the async/await + fetch showcase (milestone 3):
 *   - fetchHello: one await, branches on resp.ok
 *   - loadBoth: two SEQUENTIAL awaits, values flow into local variables
 *   - loadFail: the error path — a failed request resolves with
 *     { ok = false, error } and is shown via resp.error
 *   - loadPlain: `await` on a non-future passes the value through
 *   - useRequest: auto-fetch on mount (loading/data/error) + refetch;
 *     the request runs in the background networkLoop worker, so the UI
 *     never blocks.
 *
 * The main program (demo/main.lua) builds the docs/lib HTTP client and
 * injects it with ui.setHttpClient(); without it every fetch resolves with
 * { ok = false, error = "http client not set: ..." }.
 */

import { ACCENT, DIM, FAINT } from '../lib/theme';
import { shortError } from '../lib/format';

const URL_HELLO = 'http://192.168.1.4/hello';
const URL_TWO = 'http://192.168.1.4/quote';
const URL_FAIL = 'http://192.168.1.4/fail';
const URL_REQ = 'http://192.168.1.4/status';

export function NetworkTab() {
  const [status, setStatus] = useState('press a button');
  const [a, setA] = useState('-');
  const [b, setB] = useState('-');
  const [plain, setPlain] = useState('-');
  const [count, setCount] = useState(0);

  async function fetchHello() {
    setStatus('fetching...');
    const resp = await fetch(URL_HELLO);
    if (resp.ok) {
      const msg = resp.json();
      setStatus(msg && msg.msg ? 'hello: ' + msg.msg : 'status ' + (resp.status || '?'));
    } else {
      setStatus('error: ' + shortError(resp.error || ('http ' + (resp.status || '?'))));
    }
  }

  async function loadBoth() {
    setStatus('two sequential awaits...');
    const r1 = await fetch(URL_HELLO);
    const t1 = r1.ok ? 'ok' : 'error: ' + shortError(r1.error || 'failed');
    setA(t1);
    const r2 = await fetch(URL_TWO);
    const t2 = r2.ok ? 'ok' : 'error: ' + shortError(r2.error || 'failed');
    setB(t2);
    setStatus('done: ' + t1 + ' / ' + t2);
  }

  async function loadFail() {
    setStatus('requesting a failing url...');
    const r = await fetch(URL_FAIL);
    setStatus(r.ok ? 'unexpected ok' : 'failed: ' + shortError(r.error || 'unknown'));
  }

  async function loadPlain() {
    const v = await 42; // awaiting a non-future passes the value through
    setPlain('v=' + v);
  }

  const req = useRequest(() => fetch(URL_REQ));

  return (
    <Box style={{ flexDirection: 'column', alignItems: 'flex-start' }}>
      <Text style={{ fontSize: 1, color: FAINT, marginBottom: 4 }}>network: async/await + fetch</Text>
      <Text style={{ fontSize: 1, color: ACCENT }}>{status}</Text>

      <Box style={{ flexDirection: 'row', gap: 4, marginTop: 2, marginBottom: 4 }}>
        <Button label="hello" style={{ width: 44, height: 18, fontSize: 1, padding: 2 }} onClick={fetchHello} />
        <Button label="both" style={{ width: 44, height: 18, fontSize: 1, padding: 2 }} onClick={loadBoth} />
        <Button label="fail" style={{ width: 44, height: 18, fontSize: 1, padding: 2 }} onClick={loadFail} />
        <Button label="plain" style={{ width: 44, height: 18, fontSize: 1, padding: 2 }} onClick={loadPlain} />
      </Box>

      <Text style={{ fontSize: 1, color: DIM }}>A: {a}</Text>
      <Text style={{ fontSize: 1, color: DIM }}>B: {b}</Text>
      <Text style={{ fontSize: 1, color: DIM, marginBottom: 4 }}>plain: {plain}</Text>

      <Text style={{ fontSize: 1, color: FAINT, marginBottom: 2 }}>useRequest: 3 states + refetch</Text>
      <Text style={{ fontSize: 1, color: ACCENT }}>
        {req.loading ? 'loading...' : req.error ? 'error: ' + shortError(req.error) : req.data ? 'body: ' + req.data.body : 'empty'}
      </Text>
      <Box style={{ flexDirection: 'row', gap: 4, marginTop: 2 }}>
        <Button label="refetch" style={{ width: 56, height: 18, fontSize: 1, padding: 2 }} onClick={req.refetch} />
        <Button label="count+" style={{ width: 56, height: 18, fontSize: 1, padding: 2 }} onClick={() => setCount(count + 1)} />
      </Box>
      <Text style={{ fontSize: 1, color: DIM, marginTop: 2 }}>count: {count}</Text>
    </Box>
  );
}
