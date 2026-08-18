/**
 * Tab navigation for the showcase demo. Two rows of three tabs; the active
 * tab gets the accent border + a brighter background. Clicking a tab calls
 * onSelect(id), which switches the App's `tab` state and re-renders.
 *
 * Note: tabs are conditionally rendered children of the content box, so each
 * tab switch REMOUNTS the tab component (paths are stable only while the
 * tree structure is static) — tab-local state resets when you switch away
 * and back, which is the documented MVP behavior.
 */

import { ACCENT, ACTIVE_BG, BTN_BG, BORDER } from '../lib/theme';

function TabButton({
  id,
  label,
  active,
  onSelect,
}: {
  id: string;
  label: string;
  active: boolean;
  onSelect: (id: string) => void;
}) {
  return (
    <Button
      label={label}
      style={{
        height: 20,
        padding: 4,
        fontSize: 1,
        backgroundColor: active ? ACTIVE_BG : BTN_BG,
        borderColor: active ? ACCENT : BORDER,
      }}
      onClick={() => onSelect(id)}
    />
  );
}

export function TabBar({
  active,
  onSelect,
}: {
  active: string;
  onSelect: (id: string) => void;
}) {
  return (
    <Box style={{ width: '100%', flexDirection: 'column', gap: 4, marginBottom: 6 }}>
      <Box style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
        <TabButton id="home" label="Home" active={active === 'home'} onSelect={onSelect} />
        <TabButton id="layout" label="Layout" active={active === 'layout'} onSelect={onSelect} />
        <TabButton id="counter" label="Counter" active={active === 'counter'} onSelect={onSelect} />
      </Box>
      <Box style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
        <TabButton id="input" label="Input" active={active === 'input'} onSelect={onSelect} />
        <TabButton id="scroll" label="Scroll" active={active === 'scroll'} onSelect={onSelect} />
        <TabButton id="network" label="Network" active={active === 'network'} onSelect={onSelect} />
      </Box>
      <Box style={{ flexDirection: 'row', justifyContent: 'flex-start' }}>
        <TabButton id="control" label="Control" active={active === 'control'} onSelect={onSelect} />
      </Box>
    </Box>
  );
}
