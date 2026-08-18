/**
 * Switch tab — toggle switch showcase: demonstrates the <Switch> component
 * with multiple independent toggles and dynamic feedback text.
 */

import { DIM, FAINT, GREEN } from '../lib/theme';

export function SwitchTab() {
  const [a, setA] = useState(true);
  const [b, setB] = useState(false);

  return (
    <Box style={{ flexDirection: 'column', alignItems: 'flex-start' }}>
      <Text style={{ fontSize: 1, color: FAINT, marginBottom: 4 }}>toggle controls</Text>

      <Box style={{ flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 6 }}>
        <Text style={{ fontSize: 1, color: a ? GREEN : DIM, width: 80 }}>WiFi</Text>
        <Switch value={a} onChange={setA} />
        <Text style={{ fontSize: 1, color: DIM }}>{a ? 'ON' : 'OFF'}</Text>
      </Box>

      <Box style={{ flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 6 }}>
        <Text style={{ fontSize: 1, color: b ? GREEN : DIM, width: 80 }}>Bluetooth</Text>
        <Switch value={b} onChange={setB} />
        <Text style={{ fontSize: 1, color: DIM }}>{b ? 'ON' : 'OFF'}</Text>
      </Box>

      <Text style={{ fontSize: 1, color: FAINT, marginTop: 4 }}>
        {a ? 'connected' : 'disconnected'}
      </Text>
    </Box>
  );
}
