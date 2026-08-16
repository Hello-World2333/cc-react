/**
 * Multi-file fixture — exercised by scripts/test_multiimport.lua.
 *
 * Covers the import mechanisms added with multi-file support:
 *   - hooks (useState) inside an imported component file        (Counter)
 *   - a name collision: two files export the same component name (Widget /
 *     Widget in components/extra) — esbuild renames one consistently
 *   - a default export imported without braces                   (DefaultThing)
 *   - a .ts helper module (no JSX) providing constants + a pure function,
 *     including a hex color constant that reaches the runtime as a STRING
 *     (runtime __color parses hex strings; compile-time folding only sees
 *     literals in the same file)
 */

import { Counter } from './components/Counter';
import { Widget } from './components/Widget';
import { Widget as ExtraWidget } from './components/extra/Widget';
import DefaultThing from './components/DefaultThing';
import { ACCENT, MARK, formatLabel } from './lib/format';

function App() {
  return (
    <Panel style={{ flexDirection: 'column', gap: 4 }}>
      <Counter />
      <Widget label="one" />
      <ExtraWidget label="two" />
      <DefaultThing accent={ACCENT} />
      <Text>{MARK + ' ' + formatLabel(7)}</Text>
    </Panel>
  );
}

render(<App />);
