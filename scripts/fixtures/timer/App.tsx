/**
 * Timer fixture — exercises setTimeout and setInterval (headless test:
 * scripts/test_timer.lua).
 *
 * Behaviors covered:
 *   - setTimeout fires a callback after a delay
 *   - setInterval fires a callback repeatedly
 *   - clearTimeout cancels a pending timeout
 *   - clearInterval cancels a pending interval
 */

function TimerDemo() {
  const [timeoutResult, setTimeoutResult] = useState('none');
  const [intervalCount, setIntervalCount] = useState(0);
  const [status, setStatus] = useState('idle');
  const [intervalId, setIntervalId] = useState(0);

  function startTimeout() {
    setTimeoutResult('pending');
    setTimeout(() => {
      setTimeoutResult('fired');
    }, 100);
  }

  function startInterval() {
    setIntervalCount(0);
    setStatus('running');
    const id = setInterval(() => {
      setIntervalCount((prev: number) => prev + 1);
    }, 50);
    setIntervalId(id);
  }

  function stopInterval() {
    if (intervalId) {
      clearInterval(intervalId);
      setStatus('stopped');
    }
  }

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
      <Text style={{ color: '#8a8a95' }}>setTimeout</Text>
      <Text style={{ color: '#7ec8ff' }}>timeout: {timeoutResult}</Text>
      <Box style={{ flexDirection: 'row', gap: 8, marginTop: 4 }}>
        <Button label="startTimeout" onClick={startTimeout} />
      </Box>

      <Text style={{ color: '#8a8a95', marginTop: 8 }}>setInterval</Text>
      <Text style={{ color: '#7ec8ff' }}>count: {intervalCount}</Text>
      <Text style={{ color: '#7ec8ff' }}>status: {status}</Text>
      <Box style={{ flexDirection: 'row', gap: 8, marginTop: 4 }}>
        <Button label="startInterval" onClick={startInterval} />
        <Button label="stopInterval" onClick={stopInterval} />
      </Box>
    </Panel>
  );
}

render(<TimerDemo />);
