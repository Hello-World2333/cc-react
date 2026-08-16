/**
 * Home tab — the static-rendering showcase: title, subtitle, the feature
 * list (mapped from lib/features.ts) and three color swatches showing the
 * #rgb / #rrggbb / #aarrggbb formats (constants imported from lib/theme.ts
 * reach the runtime as strings and are parsed by the runtime's __color).
 */

import { FEATURES } from '../lib/features';
import { plural } from '../lib/format';
import { DIM, FAINT, GREEN, RED, TEXT, TRANSLUCENT } from '../lib/theme';

export function HomeTab() {
  return (
    <Box style={{ flexDirection: 'column', alignItems: 'flex-start' }}>
      <Text style={{ fontSize: 3, color: TEXT, marginBottom: 2 }}>cc-react</Text>
      <Text style={{ fontSize: 1, color: DIM }}>React-style UI for CC: Tweaked</Text>
      <Text style={{ fontSize: 1, color: DIM, marginBottom: 6 }}>+ Tom's Peripherals GPU</Text>

      <Text style={{ fontSize: 1, color: FAINT }}>all {plural(FEATURES.length, 'feature')}:</Text>
      <Box style={{ flexDirection: 'column', marginTop: 2, marginBottom: 6 }}>
        {FEATURES.map((f) => (
          <Text style={{ fontSize: 1, color: '#c8c8d4' }}>{f}</Text>
        ))}
      </Box>

      <Box style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
        <Box style={{ width: 28, height: 12, backgroundColor: RED }} />
        <Box style={{ width: 28, height: 12, backgroundColor: GREEN }} />
        <Box style={{ width: 28, height: 12, backgroundColor: TRANSLUCENT }} />
      </Box>
      <Text style={{ fontSize: 1, color: FAINT, marginTop: 2 }}>#rgb #rrggbb #aarrggbb</Text>

      <Text style={{ fontSize: 1, color: FAINT, marginTop: 8 }}>click a tab above to explore</Text>
    </Box>
  );
}
