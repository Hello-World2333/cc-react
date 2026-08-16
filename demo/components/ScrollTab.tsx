/**
 * Scroll tab — the <Scroll> showcase: 12 numbered rows (vertical overflow),
 * one over-long row (clipped horizontally to the viewport), and a Bottom
 * button that stays clickable after scrolling (click-through). `scrollStep`
 * comes from state — step-/step+ change how many px one wheel notch moves
 * (4..24), and the current value is shown through lib/format's pad2.
 */

import { ACCENT, DIM, FAINT, YELLOW } from '../lib/theme';
import { pad2, plural } from '../lib/format';

const ROWS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];

export function ScrollTab() {
  const [clicks, setClicks] = useState(0);
  const [step, setStep] = useState(8);

  return (
    <Box style={{ flexDirection: 'column', alignItems: 'flex-start' }}>
      <Text style={{ fontSize: 1, color: FAINT, marginBottom: 4 }}>scroll container</Text>
      <Text style={{ fontSize: 1, color: ACCENT }}>clicks: {plural(clicks, 'click')}</Text>

      <Box style={{ flexDirection: 'row', alignItems: 'center', gap: 4, marginTop: 2, marginBottom: 4 }}>
        <Button
          label="step-"
          style={{ width: 40, height: 18, fontSize: 1, padding: 2 }}
          onClick={() => setStep(Math.max(4, step - 4))}
        />
        <Button
          label="step+"
          style={{ width: 40, height: 18, fontSize: 1, padding: 2 }}
          onClick={() => setStep(Math.min(24, step + 4))}
        />
        <Text style={{ fontSize: 1, color: DIM }}>step {pad2(step)}px</Text>
      </Box>

      <Scroll style={{ width: '100%', height: 110, flexDirection: 'column', gap: 4, scrollStep: step }}>
        {ROWS.map((i) => (
          <Text style={{ color: ACCENT }}>row {i}</Text>
        ))}
        <Text style={{ color: YELLOW }}>
          this row is much longer than the viewport, clipped horizontally
        </Text>
        <Button
          label="Bottom"
          style={{ width: '100%', height: 24, fontSize: 1, padding: 4 }}
          onClick={() => setClicks(clicks + 1)}
        />
      </Scroll>
    </Box>
  );
}
