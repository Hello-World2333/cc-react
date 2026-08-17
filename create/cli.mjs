#!/usr/bin/env node
/**
 * create-cc-react — scaffold a new cc-react project.
 *
 * Usage:
 *   npm create cc-react my-app
 *   npx create-cc-react my-app
 *
 * Generates a minimal cc-react project with:
 *   src/App.tsx      starter component
 *   src/main.tsx     entry point (render)
 *   main.lua         CC host program (simpleParallel + GPU)
 *   tsconfig.json    configured for cc-react (jsx: react-jsx, paths)
 *   package.json     with @linyun-host/cc-react dependency + scripts
 *   .gitignore
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// Template files
// ---------------------------------------------------------------------------

const GITIGNORE = `node_modules/
dist/
*.lua
!main.lua
`;

const PACKAGE_JSON = (name) => JSON.stringify({
  name,
  version: '0.1.0',
  private: true,
  type: 'module',
  scripts: {
    build: 'cc-react src/App.tsx dist/ui.lua',
    dev: 'cc-react src/App.tsx dist/ui.lua --watch',
    typecheck: 'tsc --noEmit',
  },
  devDependencies: {
    '@linyun-host/cc-react': '^0.1.1',
    '@types/react': '^18.0.0',
    'typescript': '^5.4.0',
  },
}, null, 2) + '\n';

const TSCONFIG = JSON.stringify({
  compilerOptions: {
    target: 'ES2020',
    module: 'ESNext',
    moduleResolution: 'Bundler',
    jsx: 'react-jsx',
    lib: ['ES2020'],
    strict: true,
    noEmit: true,
    skipLibCheck: true,
    forceConsistentCasingInFileNames: true,
    types: ['@linyun-host/cc-react/framework'],
  },
  include: ['src/**/*.tsx', 'src/**/*.ts'],
}, null, 2) + '\n';

const APP_TSX = `function App() {
  const [count, setCount] = useState(0);

  return (
    <Box
      style={{
        width: '100%',
        height: '100%',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: '#131318',
        padding: 10,
      }}
    >
      <Text style={{ fontSize: 3, color: '#ffffff' }}>cc-react</Text>
      <Text style={{ fontSize: 2, color: '#7ec8ff', marginTop: 8 }}>
        Count: {count}
      </Text>
      <Box style={{ flexDirection: 'row', gap: 8, marginTop: 8 }}>
        <Button
          label="-"
          style={{ width: 40, height: 24, fontSize: 1 }}
          onClick={() => setCount(count - 1)}
        />
        <Button
          label="+"
          style={{ width: 40, height: 24, fontSize: 1 }}
          onClick={() => setCount(count + 1)}
        />
      </Box>
    </Box>
  );
}

render(<App />);
`;

const MAIN_LUA = `-- cc-react host program
-- Runs the compiled UI module as a simpleParallel task alongside
-- any other tasks (network, etc.).
local simpleParallel = require("lib.simpleParallel")
local ui = require("ui")

-- Optional: network client (docs/lib HTTP stack)
-- local IP = require("lib.ip")
-- local HTTP = require("lib.http")
-- ui.setHttpClient(HTTP.newClient(IP.new({...}), { dnsServer = "8.8.8.8", timeout = 10 }))

-- Optional: Chinese font support
-- ui.setChineseFont("hanchan16-common.fnt")

simpleParallel.add(function() ui.start("left") end)
simpleParallel.start()
`;

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function usage() {
  console.log(`Usage: create-cc-react <project-name>

Scaffold a new cc-react project.

Examples:
  npm create cc-react my-app
  npx create-cc-react my-app`);
}

function mkdirp(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function write(filepath, content) {
  fs.writeFileSync(filepath, content, 'utf8');
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length === 0 || args[0] === '-h' || args[0] === '--help') {
    usage();
    process.exit(args[0] ? 0 : 1);
  }

  const projectName = args[0];
  const projectDir = path.resolve(process.cwd(), projectName);

  if (fs.existsSync(projectDir)) {
    console.error(`Error: directory "${projectDir}" already exists.`);
    process.exit(1);
  }

  console.log(`\n  Creating cc-react project: ${projectName}\n`);

  // Create directory structure
  mkdirp(path.join(projectDir, 'src'));

  // Write files
  write(path.join(projectDir, '.gitignore'), GITIGNORE);
  write(path.join(projectDir, 'package.json'), PACKAGE_JSON(projectName));
  write(path.join(projectDir, 'tsconfig.json'), TSCONFIG);
  write(path.join(projectDir, 'src/App.tsx'), APP_TSX);
  write(path.join(projectDir, 'main.lua'), MAIN_LUA);

  console.log('  Generated files:');
  console.log('    .gitignore');
  console.log('    package.json');
  console.log('    tsconfig.json');
  console.log('    src/App.tsx');
  console.log('    main.lua');

  // Install dependencies
  console.log('\n  Installing dependencies...\n');
  const { execSync } = await import('node:child_process');
  try {
    execSync('npm install', { cwd: projectDir, stdio: 'inherit' });
  } catch {
    console.error('\n  npm install failed. Run "npm install" manually.\n');
  }

  console.log(`
  Done! Get started:

    cd ${projectName}
    npm run build          # compile src/App.tsx -> dist/ui.lua
    npm run dev            # watch mode (auto-rebuild on save)

  Deploy to CC: Tweaked:

    1. Copy dist/ui.lua + main.lua + lib/ to your computer directory
    2. Run: lua main.lua left

  Happy coding!
`);
}

main();
