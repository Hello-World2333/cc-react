/**
 * Control tab — demonstrates the <ProgressBar> and <Slider> components.
 * Shows a slider controlling a progress bar, plus independent examples.
 */

import { ACCENT, DIM, FAINT, GREEN, YELLOW } from '../lib/theme';

export function ControlTab() {
  const [progress, setProgress] = useState(0.5);
  const [volume, setVolume] = useState(0.7);
  const [brightness, setBrightness] = useState(0.3);

  return (
    <Box style={{ flexDirection: 'column', alignItems: 'flex-start' }}>
      <Text style={{ fontSize: 1, color: FAINT, marginBottom: 4 }}>progress + slider</Text>

      {/* Progress bar driven by slider */}
      <Text style={{ fontSize: 1, color: DIM, marginBottom: 2 }}>
        Progress: {Math.round(progress * 100)}%
      </Text>
      <ProgressBar value={progress} style={{ width: 150, height: 9, marginBottom: 4 }} />
      <Slider
        value={progress}
        onChange={setProgress}
        style={{ width: 150, height: 9, marginBottom: 8 }}
      />

      {/* Volume slider with label */}
      <Text style={{ fontSize: 1, color: DIM, marginBottom: 2 }}>
        Volume: {Math.round(volume * 100)}%
      </Text>
      <Box style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
        <Text style={{ fontSize: 1, color: volume > 0 ? GREEN : DIM }}>♪</Text>
        <Slider
          value={volume}
          onChange={setVolume}
          style={{ width: 120, height: 9 }}
          color={GREEN}
        />
      </Box>

      <Text style={{ fontSize: 1, color: FAINT, marginTop: 6, marginBottom: 4 }}>
        brightness
      </Text>
      <Slider
        value={brightness}
        onChange={setBrightness}
        style={{ width: 100, height: 9, marginBottom: 4 }}
        color={YELLOW}
      />
      <ProgressBar
        value={brightness}
        style={{ width: 100, height: 9 }}
        color={YELLOW}
      />
    </Box>
  );
}
