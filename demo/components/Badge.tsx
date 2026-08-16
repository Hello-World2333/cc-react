/**
 * Demo "big number!" badge — a small stateless component in its own file,
 * conditionally rendered by CounterTab when count >= 5.
 */

import { ACCENT, PANEL_BG } from '../lib/theme';

export function BigNumberBadge() {
  return (
    <Panel style={{ marginTop: 8, padding: 8, backgroundColor: PANEL_BG }}>
      <Text style={{ color: ACCENT }}>big number!</Text>
    </Panel>
  );
}
