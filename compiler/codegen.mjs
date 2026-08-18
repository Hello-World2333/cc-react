/**
 * JSX → Lua code generator.
 *
 * Input: a Babel AST of the esbuild-BUNDLED entry (TS stripped, JSX
 * preserved; all imports across files have already been inlined by esbuild,
 * so no ImportDeclaration reaches this codegen).
 *
 * Strategy (docs/architecture.md §5): components compile to Lua functions that
 * build a *style tree* via node factories (__box/__text/__panel/__button).
 * Layout and drawing happen in the embedded runtime, never in the compiled
 * code. Generated Lua is deliberately unreadable — runtime thinness wins.
 */

const RESERVED = new Set([
  'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function',
  'goto', 'if', 'in', 'local', 'nil', 'not', 'or', 'repeat', 'return', 'then',
  'true', 'until', 'while',
]);

const HOST_FACTORIES = new Map([
  ['box', '__box'], ['Box', '__box'],
  ['panel', '__panel'], ['Panel', '__panel'],
  ['text', '__text'], ['Text', '__text'],
  ['button', '__button'], ['Button', '__button'],
  ['scroll', '__scroll'], ['Scroll', '__scroll'],
  ['input', '__input'], ['Input', '__input'],
]);

export class CodegenError extends Error {}

export { containsJsx };

function luaString(s) {
  let out = '"';
  for (const ch of s) {
    const code = ch.codePointAt(0);
    if (ch === '\\') out += '\\\\';
    else if (ch === '"') out += '\\"';
    else if (ch === '\n') out += '\\n';
    else if (ch === '\r') out += '\\r';
    else if (ch === '\t') out += '\\t';
    else if (code < 32) out += '\\' + code;
    else out += ch;
  }
  return out + '"';
}

function ident(name) {
  return RESERVED.has(name) ? name + '_' : name;
}

function numLiteral(n) {
  if (!Number.isFinite(n)) throw new CodegenError('non-finite number literal: ' + n);
  return String(n);
}

function hexToArgb(hex) {
  let h = hex.slice(1);
  if (h.length === 3) h = h.split('').map((c) => c + c).join('');
  if (h.length === 6) return 0xff000000 + parseInt(h, 16);
  if (h.length === 8) return parseInt(h, 16); // aarrggbb
  throw new CodegenError('unsupported hex color: ' + hex);
}

function isHexColorString(s) {
  return /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(s);
}

/** Does this expression node contain JSX anywhere (component detection)? */
function containsJsx(node) {
  if (!node || typeof node !== 'object') return false;
  if (node.type === 'JSXElement' || node.type === 'JSXFragment') return true;
  if (Array.isArray(node)) return node.some(containsJsx);
  for (const key of Object.keys(node)) {
    if (key === 'loc' || key === 'start' || key === 'end') continue;
    if (containsJsx(node[key])) return true;
  }
  return false;
}

/** Could this expression produce an element (rather than a primitive)? */
function exprMayBeElement(node) {
  switch (node.type) {
    case 'JSXElement':
    case 'JSXFragment':
      return true;
    case 'ConditionalExpression':
      return exprMayBeElement(node.consequent) || exprMayBeElement(node.alternate);
    case 'LogicalExpression':
      return exprMayBeElement(node.left) || exprMayBeElement(node.right);
    case 'ParenthesizedExpression':
      return exprMayBeElement(node.expression);
    default:
      return false;
  }
}

const MAPPED_FUNCS = {
  useState: '__useState',
  useEffect: '__useEffect',
  fetch: '__fetch',
  useRequest: '__useRequest',
  clearTimeout: '__clearTimer',
  clearInterval: '__clearTimer',
};

// Functions that need extra hidden arguments appended (used to share an
// implementation behind two JS names while keeping one local).
const MAPPED_FUNCS_EXTRA_ARG = {
  setTimeout: ['__timerNew', 'false'],
  setInterval: ['__timerNew', 'true'],
};

/** JSX whitespace rule: text containing a newline gets its lines trimmed and
 *  joined with single spaces; single-line text is kept verbatim. */
function jsxTextValue(node) {
  let v = node.value;
  if (/[\n\r]/.test(v)) {
    v = v
      .split(/[\r\n]+/)
      .map((line) => line.trim())
      .filter((line) => line !== '')
      .join(' ');
  }
  return v;
}

export class Codegen {
  /** @param {string[]} components top-level component function names (contain JSX)
   *  @param {string[]} asyncComponents top-level async functions containing JSX
   *                                    (invalid as components; better error messages) */
  constructor(components, asyncComponents) {
    this.components = new Set(components);
    this.asyncComponents = new Set(asyncComponents || []);
    this.sawRender = false;
    this.asyncVarSeq = 0; // unique continuation parameter names per async function
  }

  // ----------------------------------------------------------------
  // Program / statements
  // ----------------------------------------------------------------

  generateProgram(ast) {
    const out = [];
    for (const stmt of ast.program.body) {
      this.genTopLevel(stmt, out);
    }
    if (!this.sawRender) {
      throw new CodegenError(
        'the compiled module needs a top-level render(<App/>) call (it mounts the root component)');
    }
    return out.join('\n');
  }

  genTopLevel(stmt, out) {
    switch (stmt.type) {
      case 'ImportDeclaration':
        // esbuild bundles all imports away before codegen; if one survives
        // (e.g. codegen used on unbundled code) it is a hard error.
        throw new CodegenError(
          'imports must be resolved by the bundler (the compiler bundles the whole app first): '
          + stmt.source.value);
      case 'ExportNamedDeclaration':
      case 'ExportDefaultDeclaration': {
        if (stmt.declaration) {
          this.genTopLevel(stmt.declaration, out);
        } else if (stmt.type === 'ExportNamedDeclaration') {
          // `export { a, b }` — esbuild emits these for the entry's exports
          // (format: 'esm'). The bindings were already emitted as top-level
          // declarations; the export statement itself is meaningless in Lua.
          // Skip it (re-exports of other modules were resolved at bundle time).
          return;
        } else {
          throw new CodegenError('unsupported export declaration (no declaration)');
        }
        return;
      }
      case 'FunctionDeclaration':
        this.genFunctionDeclaration(stmt, out);
        return;
      case 'VariableDeclaration': {
        // Arrow-function components: `const Foo = () => <.../>` compile to
        // `local function render_Foo(...)` so JSX call sites can reference them.
        const decls = [];
        let isComponentDecl = false;
        for (const d of stmt.declarations) {
          if (d.id.type === 'Identifier' && d.init
              && (d.init.type === 'ArrowFunctionExpression' || d.init.type === 'FunctionExpression')
              && containsJsx(d.init) && !d.init.async) {
            isComponentDecl = true;
          } else {
            decls.push(d);
          }
        }
        if (isComponentDecl) {
          for (const d of stmt.declarations) {
            if (d.id.type === 'Identifier' && d.init
                && (d.init.type === 'ArrowFunctionExpression' || d.init.type === 'FunctionExpression')
                && containsJsx(d.init) && !d.init.async) {
              this.genArrowComponent(d, out);
            } else {
              throw new CodegenError(
                'a component declaration must contain only the component (mixed declarators are unsupported)');
            }
          }
        } else {
          this.genVariableDeclaration(stmt, out, 0);
        }
        return;
      }
      case 'ExpressionStatement': {
        const expr = stmt.expression;
        if (expr.type === 'CallExpression' && expr.callee.type === 'Identifier' && expr.callee.name === 'render') {
          const arg = expr.arguments[0];
          if (expr.arguments.length !== 1 || arg.type !== 'JSXElement'
              || arg.openingElement.name.type !== 'JSXIdentifier'
              || arg.openingElement.attributes.length > 0
              || arg.children.some((c) => !(c.type === 'JSXText' && c.value.trim() === ''))) {
            throw new CodegenError(
              "render() must be called as render(<Component/>) with no props/children (MVP)");
          }
          const tag = arg.openingElement.name.name;
          if (this.asyncComponents.has(tag)) {
            throw new CodegenError(
              `render(<${tag}/>) but ${tag} is an async function — components must render synchronously`);
          }
          if (!this.components.has(tag)) {
            throw new CodegenError(`render(<${tag}/>) but ${tag} is not a component function`);
          }
          // Mounts the root component; the compiled module's start(side) task
          // (returned as the module table) does the GPU init + render loop.
          this.sawRender = true;
          out.push(`__mount(render_${tag})`);
          return;
        }
        out.push(this.genExpr(expr));
        return;
      }
      default:
        throw new CodegenError('unsupported top-level statement: ' + stmt.type);
    }
  }

  genArrowComponent(decl, out) {
    const name = decl.id.name;
    const fn = decl.init;
    const { params, destructures } = this.genParams(fn.params);
    out.push(`local function render_${name}(${params})`);
    this.emitDestructures(destructures, out, 1);
    if (fn.body.type === 'BlockStatement') {
      this.genStatements(fn.body.body, out, 1);
    } else {
      out.push('  return ' + this.genExpr(fn.body));
    }
    out.push('end');
  }

  genFunctionDeclaration(node, out, level = 0) {
    const name = node.id && node.id.name;
    if (!name) throw new CodegenError('anonymous top-level functions are not supported');
    const isComponent = containsJsx(node) && !node.async;
    const luaName = isComponent ? 'render_' + name : name;
    const { params, destructures } = this.genParams(node.params);
    this.line(out, level, `local function ${luaName}(${params})`);
    this.emitDestructures(destructures, out, level + 1);
    if (node.async) {
      out.push(this.indent(this.genAsyncFnBody(node), level + 1));
    } else {
      this.genStatements(node.body.body, out, level + 1);
    }
    this.line(out, level, 'end');
  }

  // ----------------------------------------------------------------
  // Parameters (incl. destructured props)
  // ----------------------------------------------------------------

  /** Lower a JS parameter list to Lua. ObjectPattern params become a synthetic
   *  `props` parameter plus `local x = props.x` destructuring statements. */
  genParams(params) {
    const names = [];
    const destructures = [];
    let synthetic = 0;
    for (const p of params) {
      if (p.type === 'Identifier') {
        names.push(ident(p.name));
      } else if (p.type === 'ObjectPattern') {
        synthetic = synthetic + 1;
        const pname = synthetic === 1 ? 'props' : 'props' + synthetic;
        names.push(pname);
        for (const prop of p.properties) {
          if (prop.type !== 'ObjectProperty' || prop.value.type !== 'Identifier') {
            throw new CodegenError(
              'object destructuring params only support simple { key } (no defaults/renames)');
          }
          destructures.push(`local ${ident(prop.value.name)} = ${pname}.${this.objectKey(prop.key)}`);
        }
      } else {
        throw new CodegenError('unsupported parameter pattern: ' + p.type);
      }
    }
    return { params: names.join(', '), destructures };
  }

  emitDestructures(destructures, out, level) {
    for (const d of destructures) this.line(out, level, d);
  }

  genStatements(stmts, out, level) {
    for (const stmt of stmts) {
      switch (stmt.type) {
        case 'VariableDeclaration':
          this.genVariableDeclaration(stmt, out, level);
          break;
        case 'FunctionDeclaration':
          this.genFunctionDeclaration(stmt, out, level);
          break;
        case 'ReturnStatement': {
          const arg = stmt.argument ? this.genExpr(stmt.argument) : '';
          this.line(out, level, 'return' + (arg ? ' ' + arg : ''));
          break;
        }
        case 'ExpressionStatement':
          this.line(out, level, this.genExpr(stmt.expression));
          break;
        case 'IfStatement':
          this.genIf(stmt, out, level);
          break;
        case 'BlockStatement':
          this.genStatements(stmt.body, out, level);
          break;
        case 'EmptyStatement':
          break;
        default:
          throw new CodegenError('unsupported statement: ' + stmt.type);
      }
    }
  }

  genIf(node, out, level) {
    const test = this.genExpr(node.test);
    this.line(out, level, `if ${test} then`);
    this.genStatementAsBlock(node.consequent, out, level + 1);
    let cur = node.alternate;
    while (cur && cur.type === 'IfStatement') {
      this.line(out, level, `elseif ${this.genExpr(cur.test)} then`);
      this.genStatementAsBlock(cur.consequent, out, level + 1);
      cur = cur.alternate;
    }
    if (cur) {
      this.line(out, level, 'else');
      this.genStatementAsBlock(cur, out, level + 1);
    }
    this.line(out, level, 'end');
  }

  /** A branch of an if/else may be a block or a single bare statement
   *  (e.g. `if (x) return y;`) — normalize both to a statement list. */
  genStatementAsBlock(stmt, out, level) {
    if (stmt.type === 'BlockStatement') {
      this.genStatements(stmt.body, out, level);
    } else {
      this.genStatements([stmt], out, level);
    }
  }

  genVariableDeclaration(node, out, level) {
    for (const decl of node.declarations) {
      this.genVarDeclarator(decl, out, level);
    }
  }

  /** Emit one `local ... = init` declarator. */
  genVarDeclarator(decl, out, level) {
    const init = decl.init ? this.genExpr(decl.init) : 'nil';
    this.genVarDeclaratorWithInit(decl, init, out, level);
  }

  /** Emit one declarator with a pre-generated init expression string. */
  genVarDeclaratorWithInit(decl, init, out, level) {
    const pattern = decl.id;
    if (pattern.type === 'Identifier') {
      this.line(out, level, `local ${ident(pattern.name)} = ${init}`);
    } else if (pattern.type === 'ArrayPattern') {
      const names = pattern.elements.map((el) => {
        if (!el) return '_';
        if (el.type === 'Identifier') return ident(el.name);
        throw new CodegenError('array destructuring only supports identifiers');
      });
      this.line(out, level, `local ${names.join(', ')} = ${init}`);
    } else if (pattern.type === 'ObjectPattern') {
      for (const prop of pattern.properties) {
        if (prop.type !== 'ObjectProperty' || prop.value.type !== 'Identifier') {
          throw new CodegenError('object destructuring only supports simple { key }');
        }
        const key = this.objectKey(prop.key);
        this.line(out, level, `local ${ident(prop.value.name)} = ${init}.${key}`);
      }
    } else {
      throw new CodegenError('unsupported variable pattern: ' + pattern.type);
    }
  }

  line(out, level, text) {
    out.push('  '.repeat(level) + text);
  }

  /** Indent every line of a multi-line Lua string by `level` steps. */
  indent(text, level) {
    const pad = '  '.repeat(level);
    return text
      .split('\n')
      .map((l) => (l === '' ? '' : pad + l))
      .join('\n');
  }

  // ----------------------------------------------------------------
  // Async functions (milestone 3): `await` → event-driven continuations
  // ----------------------------------------------------------------
  //
  // An async function runs synchronously until its first `await`, then
  // registers a continuation closure with the awaited future (__await) and
  // returns its own future (__newFuture, resolved with the function's return
  // value). The continuation contains everything after the await — including
  // further awaits, which recursively register their own continuations — so
  // no native Lua coroutine is ever created.
  //
  // v1 scope (documented in README): one `await` per statement, at statement
  // level (variable declaration init, assignment/expression, return) — not
  // inside if/else branches, and not inside loops (loops are unsupported in
  // the codegen generally). Nested async functions are self-contained.

  /** Does this node (or subtree) contain an await? Nested async functions are
   *  self-contained (their awaits belong to them), so they are not descended. */
  containsAwait(node) {
    if (!node || typeof node !== 'object') return false;
    if (node.type === 'AwaitExpression') return true;
    if ((node.type === 'FunctionDeclaration' || node.type === 'ArrowFunctionExpression'
         || node.type === 'FunctionExpression') && node.async) return false;
    if (Array.isArray(node)) return node.some((n) => this.containsAwait(n));
    for (const key of Object.keys(node)) {
      if (key === 'loc' || key === 'start' || key === 'end') continue;
      if (this.containsAwait(node[key])) return true;
    }
    return false;
  }

  /** The single AwaitExpression in a subtree; errors on 0 or 2+ awaits. */
  findSingleAwait(node, count = { n: 0 }) {
    if (!node || typeof node !== 'object') return null;
    if (node.type === 'AwaitExpression') {
      count.n += 1;
      return node;
    }
    if ((node.type === 'FunctionDeclaration' || node.type === 'ArrowFunctionExpression'
         || node.type === 'FunctionExpression') && node.async) return null;
    if (Array.isArray(node)) {
      let found = null;
      for (const c of node) {
        const r = this.findSingleAwait(c, count);
        if (r) found = r;
      }
      return found;
    }
    for (const key of Object.keys(node)) {
      if (key === 'loc' || key === 'start' || key === 'end') continue;
      const r = this.findSingleAwait(node[key], count);
      if (r) return r;
    }
    return null;
  }

  /** Copy a node subtree with the await expression replaced by a parameter
   *  identifier (the value the continuation receives). */
  replaceAwait(node, param) {
    if (!node || typeof node !== 'object') return node;
    if (node.type === 'AwaitExpression') return { type: 'Identifier', name: param };
    if ((node.type === 'FunctionDeclaration' || node.type === 'ArrowFunctionExpression'
         || node.type === 'FunctionExpression') && node.async) return node;
    const clone = { ...node };
    for (const key of Object.keys(node)) {
      if (key === 'loc' || key === 'start' || key === 'end') continue;
      const v = node[key];
      if (Array.isArray(v)) clone[key] = v.map((c) => this.replaceAwait(c, param));
      else if (v && typeof v === 'object') clone[key] = this.replaceAwait(v, param);
    }
    return clone;
  }

  /** The async function body: create the invocation future, then lower the
   *  body statements (or resolve immediately for an expression body). */
  genAsyncFnBody(node) {
    const body = [];
    this.asyncVarSeq = 0;
    body.push('local __self = __newFuture()');
    if (node.body.type === 'BlockStatement') {
      this.genAsyncStmts(node.body.body, body, 1, false);
    } else {
      body.push('  __resolveFuture(__self, ' + this.genExpr(node.body) + ')');
    }
    return body.join('\n');
  }

  /** Lower a statement list inside an async body. Statements before the first
   *  await run here; the await statement registers a continuation that runs
   *  the rest of the list (recursively lowered). A list that completes without
   *  an await finishes the async body: the invocation future is resolved. */
  genAsyncStmts(stmts, out, level, inCont) {
    // Bare blocks don't create Lua scopes in this codegen — splice their
    // statements so an await inside one is handled like a direct statement.
    const flat = [];
    for (const s of stmts) {
      if (s.type === 'BlockStatement') flat.push(...s.body);
      else flat.push(s);
    }
    let awIdx = -1;
    for (let i = 0; i < flat.length; i++) {
      if (this.containsAwait(flat[i])) { awIdx = i; break; }
    }
    if (awIdx >= 0) {
      for (let j = 0; j < awIdx; j++) {
        this.genAsyncStmt(flat[j], out, level, inCont);
      }
      this.genAwaitStmt(flat[awIdx], flat.slice(awIdx + 1), out, level, inCont);
      return;
    }
    // No await in this list: emit everything; a trailing return already
    // resolved the future, otherwise the async body completes here.
    let lastWasReturn = false;
    for (const s of flat) {
      lastWasReturn = this.genAsyncStmt(s, out, level, inCont);
    }
    if (!lastWasReturn) {
      this.line(out, level, '__resolveFuture(__self, nil)');
    }
  }

  /** One statement in an async body. Returns true when the statement ends the
   *  current scope with a return (so the caller can skip the resolve epilogue
   *  that would be dead code after it). */
  genAsyncStmt(stmt, out, level, inCont) {
    switch (stmt.type) {
      case 'VariableDeclaration':
        this.genVariableDeclaration(stmt, out, level);
        return false;
      case 'ReturnStatement': {
        const arg = stmt.argument ? this.genExpr(stmt.argument) : 'nil';
        this.line(out, level, `__resolveFuture(__self, ${arg})`);
        this.line(out, level, inCont ? 'return' : 'return __self');
        return true;
      }
      case 'ExpressionStatement':
        this.line(out, level, this.genExpr(stmt.expression));
        return false;
      case 'IfStatement':
        this.genIfAsync(stmt, out, level, inCont);
        return false;
      case 'BlockStatement':
        for (const s of stmt.body) this.genAsyncStmt(s, out, level, inCont);
        return false;
      case 'EmptyStatement':
        return false;
      default:
        throw new CodegenError('unsupported statement in async function: ' + stmt.type);
    }
  }

  /** if/else inside an async body: branches may contain returns (which must
   *  resolve the invocation future) but not awaits (v1 limitation). */
  genIfAsync(node, out, level, inCont) {
    const test = this.genExpr(node.test);
    this.line(out, level, `if ${test} then`);
    this.genAsyncBlock(node.consequent, out, level + 1, inCont);
    let cur = node.alternate;
    while (cur && cur.type === 'IfStatement') {
      this.line(out, level, `elseif ${this.genExpr(cur.test)} then`);
      this.genAsyncBlock(cur.consequent, out, level + 1, inCont);
      cur = cur.alternate;
    }
    if (cur) {
      this.line(out, level, 'else');
      this.genAsyncBlock(cur, out, level + 1, inCont);
    }
    this.line(out, level, 'end');
  }

  genAsyncBlock(stmt, out, level, inCont) {
    if (stmt.type === 'BlockStatement') {
      for (const s of stmt.body) this.genAsyncStmt(s, out, level, inCont);
    } else {
      this.genAsyncStmt(stmt, out, level, inCont);
    }
  }

  /** Lower the statement that contains the (single) await: evaluate the
   *  awaited expression, register the continuation (everything after the
   *  await, recursively lowered), and — in the function body (not inside a
   *  continuation) — return the invocation future. */
  genAwaitStmt(stmt, rest, out, level, inCont) {
    const param = '__v' + (++this.asyncVarSeq);
    const open = (operandExpr, pname) => {
      this.line(out, level, `__await(${operandExpr}, function(${pname})`);
    };
    const close = () => {
      this.line(out, level, 'end)');
      if (!inCont) this.line(out, level, 'return __self');
    };

    if (stmt.type === 'VariableDeclaration') {
      // `const x = await E;` — declarators before the awaited one run here;
      // the awaited binding (and any declarators after it) live in the
      // continuation.
      let awIdx = -1;
      for (let k = 0; k < stmt.declarations.length; k++) {
        if (this.containsAwait(stmt.declarations[k])) { awIdx = k; break; }
      }
      for (let k = 0; k < awIdx; k++) this.genVarDeclarator(stmt.declarations[k], out, level);
      const d = stmt.declarations[awIdx];
      const aw = this.findSingleAwait(d.init);
      if (aw == null || aw.n > 1) {
        throw new CodegenError('multiple awaits in one statement are not supported (split them)');
      }
      const operand = this.genExpr(aw.argument);
      if (d.init.type === 'AwaitExpression' && d.id.type === 'Identifier') {
        // `const x = await E` — the continuation parameter IS x.
        open(operand, ident(d.id.name));
        for (let k = awIdx + 1; k < stmt.declarations.length; k++) {
          this.genVarDeclarator(stmt.declarations[k], out, level + 1);
        }
        this.genAsyncStmts(rest, out, level + 1, true);
        close();
      } else {
        // await nested in the init (or destructuring pattern): a temp
        // parameter, then the declarator is re-emitted with the value
        // substituted.
        open(operand, param);
        this.genVarDeclaratorWithInit(d, this.replaceAwait(d.init, param), out, level + 1);
        for (let k = awIdx + 1; k < stmt.declarations.length; k++) {
          this.genVarDeclarator(stmt.declarations[k], out, level + 1);
        }
        this.genAsyncStmts(rest, out, level + 1, true);
        close();
      }
      return;
    }

    if (stmt.type === 'ExpressionStatement') {
      const aw = this.findSingleAwait(stmt.expression);
      if (aw == null || aw.n > 1) {
        throw new CodegenError('multiple awaits in one statement are not supported (split them)');
      }
      open(this.genExpr(aw.argument));
      this.line(out, level + 1, this.genExpr(this.replaceAwait(stmt.expression, param)));
      this.genAsyncStmts(rest, out, level + 1, true);
      close();
      return;
    }

    if (stmt.type === 'ReturnStatement') {
      const aw = this.findSingleAwait(stmt.argument);
      if (aw == null || aw.n > 1) {
        throw new CodegenError('multiple awaits in one statement are not supported (split them)');
      }
      open(this.genExpr(aw.argument));
      this.line(out, level + 1,
        `__resolveFuture(__self, ${this.genExpr(this.replaceAwait(stmt.argument, param))})`);
      this.line(out, level + 1, 'return');
      close();
      return;
    }

    throw new CodegenError(
      'await inside an if/else branch is not supported yet (move the await above the branch)');
  }

  // ----------------------------------------------------------------
  // Expressions
  // ----------------------------------------------------------------

  genExpr(node) {
    switch (node.type) {
      case 'NumericLiteral':
        return numLiteral(node.value);
      case 'StringLiteral':
        return luaString(node.value);
      case 'BooleanLiteral':
        return node.value ? 'true' : 'false';
      case 'NullLiteral':
        return 'nil';
      case 'Identifier':
        return ident(node.name);
      case 'TemplateLiteral':
        return this.genTemplate(node);
      case 'BinaryExpression':
        return this.genBinary(node);
      case 'LogicalExpression':
        return `(${this.genExpr(node.left)} ${node.operator === '&&' ? 'and' : 'or'} ${this.genExpr(node.right)})`;
      case 'UnaryExpression':
        return this.genUnary(node);
      case 'ConditionalExpression':
        // Lua has no ternary; `and/or` is correct while the true branch is
        // truthy (tables from JSX, numbers, strings) — fine for the MVP.
        return `(${this.genExpr(node.test)} and ${this.genExpr(node.consequent)} or ${this.genExpr(node.alternate)})`;
      case 'CallExpression':
        return this.genCall(node);
      case 'MemberExpression':
        return this.genMember(node);
      case 'ObjectExpression':
        return this.genObject(node);
      case 'ArrayExpression':
        return this.genArray(node);
      case 'ArrowFunctionExpression':
      case 'FunctionExpression':
        return this.genFunction(node);
      case 'JSXElement':
        return this.genJsx(node);
      case 'JSXFragment':
        return this.genJsxFragment(node);
      case 'ParenthesizedExpression':
        return this.genExpr(node.expression);
      case 'AwaitExpression':
        throw new CodegenError('await is only supported at statement level inside an async function body');
      case 'TSAsExpression':
      case 'TSTypeAssertion':
      case 'TSNonNullExpression':
        return this.genExpr(node.expression);
      default:
        throw new CodegenError('unsupported expression: ' + node.type);
    }
  }

  genTemplate(node) {
    const parts = [];
    for (let i = 0; i < node.quasis.length; i++) {
      const q = node.quasis[i];
      if (q.value.cooked !== '') parts.push(luaString(q.value.cooked));
      if (i < node.expressions.length) {
        parts.push(`tostring(${this.genExpr(node.expressions[i])})`);
      }
    }
    if (parts.length === 0) return '""';
    if (parts.length === 1) return parts[0];
    return `(${parts.join(' .. ')})`;
  }

  static isStringLike(node) {
    if (!node) return false;
    if (node.type === 'StringLiteral' || node.type === 'TemplateLiteral') return true;
    if (node.type === 'BinaryExpression' && node.operator === '+') {
      return Codegen.isStringLike(node.left) || Codegen.isStringLike(node.right);
    }
    return false;
  }

  genBinary(node) {
    const op = node.operator;
    switch (op) {
      case '+':
        if (Codegen.isStringLike(node.left) || Codegen.isStringLike(node.right)) {
          return `(${this.genExpr(node.left)} .. ${this.genExpr(node.right)})`;
        }
        return `(${this.genExpr(node.left)} + ${this.genExpr(node.right)})`;
      case '-': case '*': case '/': case '%':
        return `(${this.genExpr(node.left)} ${op} ${this.genExpr(node.right)})`;
      case '**':
        return `(${this.genExpr(node.left)} ^ ${this.genExpr(node.right)})`;
      case '==': case '===':
        return `(${this.genExpr(node.left)} == ${this.genExpr(node.right)})`;
      case '!=': case '!==':
        return `(${this.genExpr(node.left)} ~= ${this.genExpr(node.right)})`;
      case '<': case '>': case '<=': case '>=':
        return `(${this.genExpr(node.left)} ${op} ${this.genExpr(node.right)})`;
      default:
        throw new CodegenError('unsupported binary operator: ' + op);
    }
  }

  genUnary(node) {
    const arg = this.genExpr(node.argument);
    switch (node.operator) {
      case '!': return `not (${arg})`;
      case '-': return `-(${arg})`;
      case '+': return `(${arg})`;
      case 'typeof': throw new CodegenError('typeof is not supported');
      default: throw new CodegenError('unsupported unary operator: ' + node.operator);
    }
  }

  genCall(node) {
    const args = node.arguments.map((a) => {
      if (a.type === 'SpreadElement') throw new CodegenError('spread in call arguments is not supported');
      return this.genExpr(a);
    });
    const callee = node.callee;

    if (callee.type === 'Identifier') {
      const name = callee.name;
      if (MAPPED_FUNCS[name]) return `${MAPPED_FUNCS[name]}(${args.join(', ')})`;
      if (MAPPED_FUNCS_EXTRA_ARG[name]) {
        const [fn, extra] = MAPPED_FUNCS_EXTRA_ARG[name];
        return `${fn}(${args.join(', ')}, ${extra})`;
      }
      if (name === 'String') return `tostring(${args.join(', ')})`;
      if (name === 'Number') return `tonumber(${args.join(', ')})`;
      if (name === 'render') throw new CodegenError('render() is only allowed at top level');
      return `${ident(name)}(${args.join(', ')})`;
    }

    if (callee.type === 'MemberExpression') {
      const obj = this.genMemberObject(callee);
      const prop = callee.computed ? this.genExpr(callee.property) : callee.property.name;
      // JS Array.prototype.map → runtime __map
      if (!callee.computed && callee.property.type === 'Identifier' && callee.property.name === 'map') {
        return `__map(${obj}, ${args.join(', ')})`;
      }
      if (!callee.computed && callee.object.type === 'Identifier' && callee.object.name === 'Math') {
        if (prop === 'round' && args.length === 1) {
          return `math.floor((${args[0]}) + 0.5)`;
        }
        const m = this.mathFunc(prop);
        if (m) return `${m}(${args.join(', ')})`;
      }
      return `${obj}.${prop}(${args.join(', ')})`;
    }

    if (callee.type === 'ArrowFunctionExpression' || callee.type === 'FunctionExpression') {
      return `(${this.genFunction(callee)})(${args.join(', ')})`;
    }

    throw new CodegenError('unsupported call callee: ' + callee.type);
  }

  mathFunc(name) {
    switch (name) {
      case 'floor': case 'ceil': case 'abs': case 'max': case 'min':
        return 'math.' + name;
      case 'round':
        return 'math.floor'; // callers pass a single arg; add 0.5 below? keep simple:
      default:
        return null;
    }
  }

  genMemberObject(node) {
    // obj in `obj.prop(...)` / `obj[...](...)` — non-computed member call
    return this.genExpr(node.object);
  }

  genMember(node) {
    if (node.computed) {
      return `${this.genExpr(node.object)}[${this.genExpr(node.property)}]`;
    }
    const prop = node.property.name;
    // JS array/string `.length` → Lua length operator
    if (prop === 'length') {
      return `#${this.genExpr(node.object)}`;
    }
    if (node.object.type === 'Identifier' && node.object.name === 'Math') {
      const m = this.mathFunc(prop);
      if (m) return m;
    }
    return `${this.genExpr(node.object)}.${prop}`;
  }

  genObject(node) {
    const parts = [];
    for (const prop of node.properties) {
      if (prop.type === 'SpreadElement') {
        throw new CodegenError('object spread is not supported');
      }
      let value;
      if (prop.type === 'ObjectMethod') {
        value = this.genFunction(prop);
      } else if (prop.type === 'ObjectProperty') {
        value = this.genObjectValue(prop.value);
      } else {
        throw new CodegenError('unsupported object property: ' + prop.type);
      }
      parts.push(`${this.objectKey(prop.key)} = ${value}`);
    }
    return `{ ${parts.join(', ')} }`;
  }

  genObjectValue(node) {
    // Hex color strings become ARGB numbers at compile time.
    if (node.type === 'StringLiteral' && isHexColorString(node.value)) {
      return numLiteral(hexToArgb(node.value));
    }
    return this.genExpr(node);
  }

  objectKey(key) {
    if (key.type === 'Identifier') return ident(key.name);
    if (key.type === 'StringLiteral') {
      const name = key.value;
      return /^[A-Za-z_][A-Za-z0-9_]*$/.test(name) && !RESERVED.has(name) ? name : `[${luaString(name)}]`;
    }
    if (key.type === 'NumericLiteral') return `[${numLiteral(key.value)}]`;
    throw new CodegenError('unsupported object key: ' + key.type);
  }

  genArray(node) {
    const hasSpread = node.elements.some((el) => el && el.type === 'SpreadElement');
    if (hasSpread) {
      const args = node.elements.map((el) => {
        if (el && el.type === 'SpreadElement') return this.genExpr(el.argument);
        return el ? this.genExpr(el) : 'nil';
      });
      return `__arr(${args.join(', ')})`;
    }
    return `{ ${node.elements.map((el) => (el ? this.genExpr(el) : 'nil')).join(', ')} }`;
  }

  genFunction(node) {
    const { params, destructures } = this.genParams(node.params);
    const body = [];
    body.push(`function(${params})`);
    this.emitDestructures(destructures, body, 1);
    if (node.async) {
      body.push(this.indent(this.genAsyncFnBody(node), 1));
    } else if (node.body.type === 'BlockStatement') {
      this.genStatements(node.body.body, body, 1);
    } else {
      body.push('  return ' + this.genExpr(node.body));
    }
    body.push('end');
    return body.join('\n');
  }

  // ----------------------------------------------------------------
  // JSX
  // ----------------------------------------------------------------

  genJsx(node) {
    const name = node.openingElement.name;
    if (name.type !== 'JSXIdentifier') {
      throw new CodegenError('JSX member expressions (Foo.Bar) are not supported');
    }
    const tag = name.name;
    const factory = HOST_FACTORIES.get(tag);
    if (factory) {
      return `${factory}(${this.genJsxProps(node)})`;
    }
    if (/^[a-z]/.test(tag)) {
      throw new CodegenError(
        `unknown intrinsic element <${tag}/> (known: Box/Panel/Text/Button/Scroll/Input)`);
    }
    if (!this.components.has(tag)) {
      throw new CodegenError(`<${tag}/> is used but no component function '${tag}' is defined`);
    }
    return `__component(${luaString(tag)}, render_${tag}, ${this.genJsxProps(node)})`;
  }

  genJsxFragment(node) {
    const children = this.jsxChildren(node.children);
    return `__box({ children = __children({ ${children} }) })`;
  }

  genJsxProps(node) {
    const parts = [];
    for (const attr of node.openingElement.attributes) {
      if (attr.type === 'JSXSpreadAttribute') {
        throw new CodegenError('JSX spread attributes are not supported');
      }
      const name = attr.name.name;
      let value;
      if (attr.value == null) {
        value = 'true';
      } else if (attr.value.type === 'StringLiteral') {
        value = this.genObjectValue(attr.value);
      } else if (attr.value.type === 'JSXExpressionContainer') {
        value = this.genExpr(attr.value.expression);
      } else if (attr.value.type === 'JSXElement') {
        value = this.genJsx(attr.value);
      } else {
        throw new CodegenError('unsupported JSX attribute value: ' + attr.value.type);
      }
      parts.push(`${ident(name)} = ${value}`);
    }

    const children = node.children
      .filter((c) => !(c.type === 'JSXText' && c.value.trim() === ''))
      .filter((c) => !(c.type === 'JSXExpressionContainer' && c.expression.type === 'JSXEmptyExpression'));
    const tag = node.openingElement.name.name;
    const kind = HOST_FACTORIES.get(tag) ? tag.toLowerCase() : null;
    if (children.length > 0) {
      if (kind === 'text' || kind === 'button' || kind === 'input') {
        for (const c of children) {
          if (c.type === 'JSXExpressionContainer' && exprMayBeElement(c.expression)) {
            throw new CodegenError(`<${tag}> children must be text (elements are not allowed inside text)`);
          }
        }
        const prop = kind === 'button' ? 'label' : kind === 'input' ? 'value' : 'text';
        parts.push(`${prop} = ${this.genTextConcat(children)}`);
      } else {
        parts.push(`children = __children({ ${this.jsxChildren(children)} })`);
      }
    }
    return `{ ${parts.join(', ')} }`;
  }

  jsxChildren(children) {
    return children
      .filter((c) => !(c.type === 'JSXText' && c.value.trim() === ''))
      .filter((c) => !(c.type === 'JSXExpressionContainer' && c.expression.type === 'JSXEmptyExpression'))
      .map((c) => {
        if (c.type === 'JSXText') return luaString(jsxTextValue(c));
        if (c.type === 'JSXExpressionContainer') return this.genExpr(c.expression);
        return this.genJsx(c);
      })
      .join(', ');
  }

  genTextConcat(children) {
    const parts = children.map((c) => {
      if (c.type === 'JSXText') return luaString(jsxTextValue(c));
      if (c.type === 'JSXExpressionContainer') return `tostring(${this.genExpr(c.expression)})`;
      throw new CodegenError('unexpected child inside text: ' + c.type);
    });
    if (parts.length === 1) return parts[0];
    return `(${parts.join(' .. ')})`;
  }
}
