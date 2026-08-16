/**
 * Demo recorded-history list. Receives the history array as a prop and maps
 * it to rows; renders nothing while the list is empty (early return null).
 *
 * The rows live inside a <Scroll> viewport: once the list grows taller than
 * `height` (default 96), the overflow is clipped and can be scrolled with the
 * mouse wheel (tm_monitor_mouse_scroll) or by touch-dragging the list.
 */

import { ACCENT, DIM, PANEL_BG } from '../lib/theme';

export function HistoryList({ history, height }: { history: number[]; height?: number }) {
  if (history.length === 0) return null;
  return (
    <Panel
      style={{
        marginTop: 8,
        padding: 8,
        backgroundColor: PANEL_BG,
        flexDirection: 'column',
        alignItems: 'center',
        width: '100%',
      }}
    >
      <Text style={{ color: DIM, marginBottom: 4 }}>Recorded:</Text>
      <Scroll
        style={{
          width: '100%',
          height: height || 96,
          flexDirection: 'column',
          alignItems: 'center',
          gap: 4,
        }}
      >
        {history.map((v) => (
          <Text style={{ color: ACCENT }}>#{v}</Text>
        ))}
      </Scroll>
    </Panel>
  );
}
