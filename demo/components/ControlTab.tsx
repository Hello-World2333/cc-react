/**
 * Control tab — demonstrates the <ProgressBar> and <Slider> components.
 * Shows a slider controlling a progress bar, plus independent examples.
 */

import { ACCENT, DIM, FAINT, GREEN, YELLOW } from '../lib/theme';

export function ControlTab() {
  const [progress, setProgress] = useState(50);
  const [volume, setVolume] = useState(70);
  const [brightness, setBrightness] = useState(80);

  return (
    <Box style={{ flexDirection: 'column', alignItems: 'flex-start' }}>
      <Text style={{ fontSize: 1, color: FAINT, marginBottom: 4 }}>progress + slider</Text>

      {/* Progress bar driven by slider (0-100) */}
      <Text style={{ fontSize: 1, color: DIM, marginBottom: 2 }}>
        Progress: {progress}%
      </Text>
      <ProgressBar
        value={progress / 100}
        style={{ width: 150, height: 9, marginBottom: 4 }}
      />
      <Slider
        value={progress}
        min={0}
        max={100}
        onChange={setProgress}
        style={{ width: 150, height: 9, marginBottom: 8 }}
      />

      {/* Volume slider with label (0-100, step 5) */}
      <Text style={{ fontSize: 1, color: DIM, marginBottom: 2 }}>
        Volume: {volume}%
      </Text>
      <Box style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
        <Text style={{ fontSize: 1, color: volume > 0 ? GREEN : DIM }}>♪</Text>
        <Slider
          value={volume}
          min={0}
          max={100}
          step={5}
          onChange={setVolume}
          style={{ width: 120, height: 9 }}
          color={GREEN}
        />
      </Box>

      <Text style={{ fontSize: 1, color: FAINT, marginTop: 6, marginBottom: 4 }}>
        brightness (0-255)
      </Text>
      <Slider
        value={brightness}
        min={0}
        max={255}
        onChange={setBrightness}
        style={{ width: 100, height: 9, marginBottom: 4 }}
        color={YELLOW}
      />
      <ProgressBar
        value={brightness / 255}
        style={{ width: 100, height: 9 }}
        color={YELLOW}
      />
    </Box>
  );
}
