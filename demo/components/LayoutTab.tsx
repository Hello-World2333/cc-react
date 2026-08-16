/**
 * Layout tab — a flexbox playground plus a padding/margin showcase.
 *
 * The playground box takes `justifyContent` and `alignItems` from state, so
 * J-/J+/A-/A+ cycle through every supported value (flex-start / center /
 * flex-end / space-between / space-around, and stretch — the three chips
 * stretch to the full container height under align: stretch). The chips are
 * labeled with a child <Text> so they have intrinsic content height.
 *
 * The padding/margin panel below uses the 4-side OBJECT forms
 * (padding: {top,right,bottom,left}) and an asymmetric margin object — the
 * runtime normalizes both into per-side numbers.
 */

import { ACCENT, BORDER, DIM, FAINT, GREEN, PANEL_BG, RED, TEXT, TRANSLUCENT } from '../lib/theme';

// NOTE: these arrays are indexed directly by state (JUSTIFIES[ji]) and the
// compiled output uses plain Lua tables, which are 1-BASED — so ji/ai start
// at 1 and the cycle math is (n % len) + 1. (.map() over them is fine either
// way: __map passes the VALUE, so 1-based storage is invisible there.)
const JUSTIFIES: ('flex-start' | 'center' | 'flex-end' | 'space-between' | 'space-around')[] = [
  'flex-start',
  'center',
  'flex-end',
  'space-between',
  'space-around',
];
const ALIGNS: ('flex-start' | 'center' | 'flex-end' | 'stretch')[] = [
  'flex-start',
  'center',
  'flex-end',
  'stretch',
];

export function LayoutTab() {
  const [ji, setJi] = useState(1);
  const [ai, setAi] = useState(1);

  return (
    <Box style={{ flexDirection: 'column', alignItems: 'flex-start' }}>
      <Text style={{ fontSize: 1, color: FAINT, marginBottom: 4 }}>flexbox playground</Text>
      <Text style={{ fontSize: 1, color: ACCENT }}>justify: {JUSTIFIES[ji]}</Text>
      <Text style={{ fontSize: 1, color: ACCENT, marginBottom: 4 }}>align: {ALIGNS[ai]}</Text>

      <Panel
        style={{
          width: '100%',
          height: 40,
          flexDirection: 'row',
          borderColor: BORDER,
          gap: 6,
          padding: 4,
          justifyContent: JUSTIFIES[ji],
          alignItems: ALIGNS[ai],
        }}
      >
        <Box style={{ width: 14, backgroundColor: RED, alignItems: 'center' }}>
          <Text style={{ fontSize: 1, color: TEXT }}>A</Text>
        </Box>
        <Box style={{ width: 14, backgroundColor: GREEN, alignItems: 'center' }}>
          <Text style={{ fontSize: 1, color: TEXT }}>B</Text>
        </Box>
        <Box style={{ width: 14, backgroundColor: ACCENT, alignItems: 'center' }}>
          <Text style={{ fontSize: 1, color: TEXT }}>C</Text>
        </Box>
      </Panel>

      <Box style={{ flexDirection: 'row', gap: 4, marginTop: 4 }}>
        <Button
          label="J-"
          style={{ width: 30, height: 18, fontSize: 1, padding: 2 }}
          onClick={() => setJi(((ji + 3) % 5) + 1)}
        />
        <Button
          label="J+"
          style={{ width: 30, height: 18, fontSize: 1, padding: 2 }}
          onClick={() => setJi((ji % 5) + 1)}
        />
        <Button
          label="A-"
          style={{ width: 30, height: 18, fontSize: 1, padding: 2 }}
          onClick={() => setAi(((ai + 2) % 4) + 1)}
        />
        <Button
          label="A+"
          style={{ width: 30, height: 18, fontSize: 1, padding: 2 }}
          onClick={() => setAi((ai % 4) + 1)}
        />
      </Box>

      <Text style={{ fontSize: 1, color: FAINT, marginTop: 8 }}>asymmetric padding/margin</Text>
      <Panel
        style={{
          width: '100%',
          flexDirection: 'column',
          alignItems: 'flex-start',
          backgroundColor: PANEL_BG,
          borderColor: BORDER,
          padding: { top: 3, right: 10, bottom: 5, left: 14 },
        }}
      >
        <Box
          style={{ width: '100%', height: 8, backgroundColor: TRANSLUCENT, margin: { top: 2, bottom: 4 } }}
        />
        <Text style={{ fontSize: 1, color: DIM }}>asymmetric box</Text>
      </Panel>
    </Box>
  );
}
