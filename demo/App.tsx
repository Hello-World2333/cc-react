/**
 * cc-react showcase demo — entry file.
 *
 * A tabbed app that exercises (almost) every feature of the framework in one
 * deployable demo. Each tab is a separate showcase component in
 * demo/components/*:
 *
 *   Home     — static rendering: title, feature list (lib/features.ts via
 *              .map()), color swatches in all three hex formats (imported
 *              from lib/theme.ts, parsed at runtime)
 *   Layout   — flexbox playground: justifyContent / alignItems cycle through
 *              every supported value; padding/margin 4-side objects
 *   Counter  — interaction loop: useState (functional updates + array
 *              spread), useEffect deps, conditional rendering, recorded
 *              history in a <Scroll>
 *   Input    — keyboard input + focus management: three controlled inputs,
 *              Tab/Shift+Tab cycling, onSubmit, onKey raw codes, long-text
 *              horizontal scrolling
 *   Scroll   — <Scroll> viewport: vertical + horizontal clipping, wheel and
 *              drag scrolling, scrollStep control, click-through
 *   Network  — async/await + fetch (sequential awaits, error path, await on
 *              a non-future) + useRequest (loading/data/error + refetch)
 *
 * Multi-file demo: every tab, plus the lib/* helper modules (theme constants,
 * feature data, pure functions — imported with aliases too), lives in its own
 * file and is bundled into the single Lua module at compile time.
 *
 * Tab-local state resets when you switch away and back: tabs are
 * conditionally rendered children, and hook state is keyed by component
 * instance path — the documented MVP behavior for structural changes.
 */

import { TabBar } from './components/TabBar';
import { HomeTab } from './components/HomeTab';
import { LayoutTab } from './components/LayoutTab';
import { CounterTab } from './components/CounterTab';
import { InputTab } from './components/InputTab';
import { ScrollTab } from './components/ScrollTab';
import { NetworkTab } from './components/NetworkTab';
import { BG } from './lib/theme';

function App() {
  const [tab, setTab] = useState('home');

  return (
    <Panel
      style={{
        width: '100%',
        height: '100%',
        flexDirection: 'column',
        backgroundColor: BG,
        padding: 8,
      }}
    >
      <TabBar active={tab} onSelect={setTab} />

      {/* The tab bar is 50px tall (2 rows); the content box fills the rest of
          a 3x4 monitor stack (192x256): 256 - 16 padding - 50 = 190. */}
      <Box style={{ width: '100%', height: 190, flexDirection: 'column' }}>
        {tab === 'home' && <HomeTab />}
        {tab === 'layout' && <LayoutTab />}
        {tab === 'counter' && <CounterTab />}
        {tab === 'input' && <InputTab />}
        {tab === 'scroll' && <ScrollTab />}
        {tab === 'network' && <NetworkTab />}
      </Box>
    </Panel>
  );
}

render(<App />);
