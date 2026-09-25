#!/usr/bin/env node
/*
 * Talks to a Haxe completion server the way the Wisdom language server will,
 * and prints what each probe actually returns.
 *
 * Usage:
 *   node scripts/display-spike.mjs <projectRoot> <file.hx> [hxmlArg ...]
 *
 * Example:
 *   node scripts/display-spike.mjs ../wisdom-app src/app/ui/SettingsPopup.hx build.hxml
 *
 * This is the reference implementation of the wire protocol, kept runnable so
 * the facts the design rests on can be re-checked against any Haxe version
 * rather than trusted from memory. Everything it demonstrates:
 *
 *   - request framing: int32 LE length (header excluded), then each argument
 *     followed by "\n"
 *   - responses arrive on STDERR, same framing; stdout is only log output
 *   - payload lines starting with \x01 are logs, \x02 marks an error response
 *   - `contents` replaces the content of an EXISTING file; `offset` counts
 *     Unicode codepoints, not UTF-16 code units
 *   - `server/invalidate` must precede every request carrying a rewritten
 *     `contents`, or results depend on request order
 *   - `-D completion` is required ON THE CACHE BUILD, see below
 *
 * Why `-D completion`: the cache build is a real compilation (there is no
 * `--display` on it), and the compilation server reuses the macro context it
 * created, so macros that choose their branch with a compile-time `#if display`
 * stay in build mode for later display requests. (wisdom now asks
 * `Context.defined("display")` at run time and is immune; tracker is not yet.) The typed modules are
 * then cached in that state and later display requests reuse them, reporting
 * tracker's `unobservedX` fields as `@props` and `@x` component arguments as
 * `(xid_, ctx_, data_, children)` instead of the declared ones.
 *
 * Measured, deterministic -- only these two inputs matter:
 *
 *   cache build | -D completion | @props reported on kit.ui.Button
 *   ------------|---------------|---------------------------------------------
 *   yes         | no            | 12: the 6 real ones + 6 unobservedX   BROKEN
 *   yes         | yes           | 6, correct                   <-- what we ship
 *   no          | no            | 6, correct
 *   no          | yes           | 6, correct
 *
 * So the define is only load-bearing ON THE CACHE BUILD. We pass it on the
 * display requests too, because Haxe keys compilation contexts on the argument
 * signature: a cache built under a different signature is a different context
 * and warms nothing (visible here as a ~10x slower first request).
 *
 * Whether a *later* request recovers depends on what else has been asked in
 * between, so from the language server's point of view this is simply
 * non-deterministic -- same hazard class as skipping `server/invalidate`. The
 * language server also filters `^unobserved[A-Z]` regardless, so a regression
 * here degrades performance rather than correctness.
 */

import {spawn} from 'child_process';
import {readFileSync} from 'fs';
import {resolve as resolvePath, join} from 'path';

const argv = process.argv.slice(2);
// Run the whole session (cache build included) without `-D completion`, to see
// what the macros do when they take their non-display branch.
const NO_COMPLETION_DEFINE = argv.includes('--no-completion-define');
const NO_CACHE_BUILD = argv.includes('--no-cache-build');
// Most projects have no `@x` function component handy; inject one so probe (d2)
// can be exercised anywhere. It also happens to be what surfaces the cache-build
// problem described above.
const INJECT_X = argv.includes('--inject-x');
// Replay probe buffers produced by the language server's own Haxe code
// (`haxe -cp src --main ProbeCheck --interp`), rather than ones built here.
// This is what proves the rewriting and the offset arithmetic agree with what
// the compiler actually accepts.
const probesFlag = argv.indexOf('--probes');
const PROBES_FILE = probesFlag !== -1 ? argv[probesFlag + 1] : null;
// Replay the three compilation-server states that matter for completion inside
// `${...}` in markup -- the one vshaxe is in, ours, and a fresh server -- and
// report whether each still completes. See `vshaxeLike()`.
const VSHAXE_LIKE = argv.includes('--vshaxe-like');
const FLAGS = ['--no-completion-define', '--no-cache-build', '--inject-x', '--vshaxe-like', '--probes', PROBES_FILE];
const [rawRoot, rawFile, ...hxmlArgs] = argv.filter(a => !FLAGS.includes(a));

if (!rawRoot || (!rawFile && !PROBES_FILE)) {
    console.error('usage: node scripts/display-spike.mjs <projectRoot> <file.hx> [hxmlArg ...]');
    process.exit(2);
}

const root = resolvePath(rawRoot);
const file = rawFile ? resolvePath(join(root, rawFile)) : null;
const hxml = hxmlArgs.length > 0 ? hxmlArgs : ['build.hxml'];

const PROBE_HEAD = '({ var _w0 = ';
const PROBE_TAIL = '; null; } : String)';

/// Wire protocol

class HaxeServer {

    constructor(root) {
        this.root = root;
        this.nextId = 1;
        this.pending = null;
        this.buffer = Buffer.alloc(0);
        this.child = spawn('haxe', ['--wait', 'stdio'], {cwd: root});
        // Responses come back on stderr. stdout carries compiler log output only.
        this.child.stderr.on('data', chunk => this.onData(chunk));
    }

    onData(chunk) {
        this.buffer = Buffer.concat([this.buffer, chunk]);
        while (this.buffer.length >= 4) {
            const len = this.buffer.readInt32LE(0);
            if (this.buffer.length < 4 + len) return;
            const payload = this.buffer.slice(4, 4 + len).toString('utf8');
            this.buffer = this.buffer.slice(4 + len);
            const resolve = this.pending;
            this.pending = null;
            if (resolve) resolve(payload);
        }
    }

    /** Send a raw argument list and resolve with the decoded payload. */
    send(args) {
        return new Promise(resolve => {
            this.pending = resolve;
            const parts = args.map(a => Buffer.from(a + '\n'));
            const len = parts.reduce((n, b) => n + b.length, 0);
            const header = Buffer.alloc(4);
            header.writeInt32LE(len, 0);   // length excludes the header itself
            this.child.stdin.write(Buffer.concat([header, ...parts]));
        });
    }

    /**
     * `withProject` false sends a bare `--display` with no hxml, which is what
     * `initialize` and `server/configure` want.
     */
    async rpc(method, params, withProject = true, completionDefine = !NO_COMPLETION_DEFINE) {
        const request = {jsonrpc: '2.0', id: this.nextId++, method, params};
        const args = withProject
            ? ['--cwd', this.root, '--no-output', '-D', 'display-details',
               ...(completionDefine ? ['-D', 'completion'] : []),
               ...hxml, '--display', JSON.stringify(request)]
            : ['--cwd', this.root, '--display', JSON.stringify(request)];

        const payload = await this.send(args);

        let isError = false;
        const text = [];
        for (const line of payload.split('\n')) {
            if (line.startsWith('\x01')) continue;          // compiler log line
            if (line.startsWith('\x02')) { isError = true; continue; }
            text.push(line);
        }
        const body = text.join('\n').trim();
        if (isError) return {rawError: body};
        try {
            const parsed = JSON.parse(body);
            if (parsed.error) {
                const messages = (parsed.error.data || []).map(d => d.message);
                return {compilerError: messages.length ? messages.join(' | ') : parsed.error.message};
            }
            return {result: parsed.result.result};
        }
        catch (_) {
            return {rawError: body.slice(0, 400)};
        }
    }

    buildCache() {
        return this.send(['--cwd', this.root, '--no-output', '--each', '--no-output',
                          '-D', 'message.no-color',
                          ...(NO_COMPLETION_DEFINE ? [] : ['-D', 'completion']),
                          ...hxml]);
    }

    kill() { this.child.kill(); }

}

/// Locating the markup literal

/**
 * Find the first `'<>` literal and where its closing quote is.
 *
 * A miniature of the scanner's pass A: `\X` consumes two characters, `$$` is a
 * literal `$`, and `${...}` re-enters Haxe code, where a nested `'...'` literal
 * (how nested markup is actually written) must not be mistaken for the end.
 */
function findMarkupLiteral(text) {
    const start = text.indexOf("'<>");
    if (start < 0) return null;

    let i = start + 1;
    while (i < text.length) {
        const c = text[i];
        if (c === '\\') { i += 2; continue; }
        if (c === '$' && text[i + 1] === '$') { i += 2; continue; }
        if (c === '$' && text[i + 1] === '{') {
            i += 2;
            let depth = 1;
            while (i < text.length && depth > 0) {
                const d = text[i];
                if (d === '\\') { i += 2; continue; }
                if (d === '{') depth++;
                else if (d === '}') depth--;
                else if (d === "'" || d === '"') {        // nested string in Haxe code
                    const quote = d;
                    i++;
                    while (i < text.length && text[i] !== quote) {
                        if (text[i] === '\\') i++;
                        i++;
                    }
                }
                i++;
            }
            continue;
        }
        if (c === "'") return {start, endExclusive: i + 1};
        i++;
    }
    return {start, endExclusive: text.length, unterminated: true};
}

/** Haxe wants codepoint offsets; a JS string index counts UTF-16 code units. */
function codepointOffset(text, index) {
    return Array.from(text.slice(0, index)).length;
}

/// Reporting

function describe(method, answer) {
    if (answer.rawError) return `RAW ERROR: ${answer.rawError.slice(0, 160)}`;
    if (answer.compilerError) return `COMPILER ERROR: ${answer.compilerError.slice(0, 160)}`;

    const r = answer.result;
    if (r == null) return 'null';

    if (method === 'display/hover') {
        const t = r.item && r.item.type;
        const bits = [`item.kind=${r.item && r.item.kind}`, `type.kind=${t && t.kind}`];
        if (t && t.kind === 'TFun') bits.push(`args=[${t.args.args.map(a => a.name).join(', ')}]`);
        if (r.item && r.item.args && r.item.args.path) bits.push(r.item.args.path.typeName);
        bits.push(`doc=${r.documentation ? 'yes' : 'no'}`);
        return bits.join(' ');
    }

    if (method === 'display/definition') {
        return r.length === 0 ? '[] (empty!)' : r.map(l => `${l.file}:${l.range.start.line + 1}`).join(', ');
    }

    // display/completion
    const kinds = {};
    for (const item of r.items) kinds[item.kind] = (kinds[item.kind] || 0) + 1;
    const props = r.items
        .filter(i => i.kind === 'ClassField' && i.args.field.meta.some(m => m.name === 'props'))
        .map(i => i.args.field.name);
    const imported = r.items.filter(i => i.kind === 'Type' && i.args.path.importStatus === 0).length;

    const bits = [`mode.kind=${r.mode.kind}`, `items=${r.items.length}`,
                  `kinds=${JSON.stringify(kinds)}`, `importedTypes=${imported}`];
    if (props.length) bits.push(`@props=[${props.join(', ')}]`);
    return bits.join(' ');
}

/// Main

async function replayProbes() {

    const {file: probeFile, probes} = JSON.parse(readFileSync(PROBES_FILE, 'utf8'));
    console.log(`probes  : ${probes.length} from ${PROBES_FILE}`);
    console.log(`file    : ${probeFile}\n`);

    const server = new HaxeServer(root);
    await server.rpc('initialize', {supportsResolve: true, maxCompletionItems: 5000}, false);
    await server.rpc('server/configure', {noModuleChecks: true}, false);
    if (!NO_CACHE_BUILD) await server.buildCache();
    await server.rpc('server/readClassPaths', {});

    let failures = 0;
    for (const probe of probes) {
        await server.rpc('server/invalidate', {file: probeFile});
        const params = {file: probeFile, contents: probe.contents, offset: probe.offset};
        if (probe.method === 'display/completion') params.wasAutoTriggered = true;

        const answer = await server.rpc(probe.method, params);
        const description = describe(probe.method, answer);
        const bad = answer.rawError || answer.compilerError || description === 'null' || description.includes('[] (empty!)');
        if (bad) failures++;
        console.log(`${bad ? 'FAIL' : 'ok  '} ${probe.label.padEnd(30)} ${description}`);
    }

    server.kill();
    if (failures > 0) {
        console.log(`\n${failures}/${probes.length} probes failed`);
        process.exit(1);
    }
    console.log(`\nall ${probes.length} probes answered`);

}

/**
 * Why `Std.` inside `${...}` in markup may complete for us and not for vshaxe.
 *
 * The wisdom and tracker macros used to pick their display branch with a
 * compile-time `#if display`. The compilation server compiles the macro
 * context once and reuses it -- `display` is not part of the signature -- so
 * after a normal build (vshaxe always starts with one) the macros stay in
 * build mode: the markup is converted to code during completion, and the
 * half-typed expression fails to parse. Libraries that test
 * `Context.defined("display")` at macro run time are immune.
 *
 * Inserts `${Std.}` -- valid in any context, static or not -- at the start
 * of the first markup literal, where it is a plain interpolation, and asks for
 * completion there in each state.
 */
async function vshaxeLike() {

    const original = readFileSync(file, 'utf8');
    const literal = findMarkupLiteral(original);
    if (!literal) {
        console.error(`No Wisdom markup literal ('<>) found in ${file}`);
        process.exit(1);
    }

    const insertAt = literal.start + 3;   // just after '<>
    const insertion = '${Std.}';
    const contents = original.slice(0, insertAt) + insertion + original.slice(insertAt);
    const offset = codepointOffset(contents, insertAt + insertion.indexOf('.') + 1);

    const states = [
        {label: 'vshaxe-like: cache build, no -D completion', cache: true, define: false},
        {label: 'ours: cache build with -D completion', cache: true, define: true},
        {label: 'fresh server, no cache build', cache: false, define: false},
    ];

    let broken = 0;
    for (const state of states) {
        const server = new HaxeServer(root);
        await server.rpc('initialize', {supportsResolve: true}, false);
        await server.rpc('server/configure', {noModuleChecks: true}, false);
        if (state.cache) {
            await server.send(['--cwd', root, '--no-output', '--each', '--no-output', '-D', 'message.no-color',
                               ...(state.define ? ['-D', 'completion'] : []), ...hxml]);
        }
        await server.rpc('server/invalidate', {file}, true, state.define);
        const answer = await server.rpc('display/completion', {file, contents, offset, wasAutoTriggered: true}, true, state.define);
        const ok = answer.result && answer.result.mode && answer.result.mode.kind === 0 && answer.result.items.length > 0;
        if (!ok) broken++;
        console.log(`${ok ? 'ok  ' : 'FAIL'} ${state.label.padEnd(46)} ${describe('display/completion', answer)}`);
        server.kill();
    }

    if (broken > 0) {
        console.log(`\n${broken}/${states.length} states cannot complete inside \${...}.`);
        console.log('A failure on the vshaxe-like line alone means the libraries still choose their display branch at macro compile time.');
        process.exit(1);
    }
    console.log('\ncompletion inside ${...} works in every server state');

}

async function main() {
    if (PROBES_FILE) return replayProbes();
    if (VSHAXE_LIKE) return vshaxeLike();

    const original = readFileSync(file, 'utf8');
    const literal = findMarkupLiteral(original);
    if (!literal) {
        console.error(`No Wisdom markup literal ('<>) found in ${file}`);
        process.exit(1);
    }

    let before = original.slice(0, literal.start);
    const after = original.slice(literal.endExclusive);

    if (INJECT_X) {
        // Insert just before the member holding the markup, so it lands inside
        // the class body whatever that member is called.
        const memberStart = original.lastIndexOf('function ', literal.start);
        const X_COMPONENT = "\n    @x function Row(label:String, count:Int = 0, @state open:Bool = false) "
                          + "return '<><div>$label ${count}</div>';\n\n    ";
        before = original.slice(0, memberStart) + X_COMPONENT + original.slice(memberStart, literal.start);
    }
    console.log(`file    : ${file}`);
    console.log(`literal : offsets ${literal.start}..${literal.endExclusive}${literal.unterminated ? ' (unterminated!)' : ''}`);
    console.log(`hxml    : ${hxml.join(' ')}\n`);

    const server = new HaxeServer(root);

    const init = await server.rpc('initialize', {supportsResolve: true, maxCompletionItems: 5000}, false);
    console.log(`initialize        : ${init.result ? `ok, ${init.result.methods.length} methods, haxe ${Object.values(init.result.haxeVersion).slice(0, 3).join('.')}` : JSON.stringify(init)}`);
    await server.rpc('server/configure', {noModuleChecks: true}, false);

    let t0 = Date.now();
    if (NO_CACHE_BUILD) {
        console.log('cache build       : skipped');
    }
    else {
        await server.buildCache();
        console.log(`cache build       : ${Date.now() - t0} ms`);
    }

    t0 = Date.now();
    const cp = await server.rpc('server/readClassPaths', {});
    console.log(`readClassPaths    : ${cp.result ? cp.result.files : '?'} files, ${Date.now() - t0} ms\n`);

    /** Splice a probe over the whole markup literal and ask Haxe about it. */
    async function probe(label, method, expr, cursorInExpr, completionDefine = true) {
        const blob = PROBE_HEAD + expr + PROBE_TAIL;
        const contents = before + blob + after;
        // `before.length`, not `literal.start`: --inject-x shifts the prefix.
        const offset = codepointOffset(contents, before.length + PROBE_HEAD.length + cursorInExpr);

        // Without this the compiler reuses a stale module and answers become
        // order-dependent: hover returns the enclosing literal instead of the
        // type, definition comes back empty, or an unrelated "Field render
        // overrides parent class" error surfaces. Whether a given request is
        // hit depends on what ran before it, which is exactly why this is
        // unconditional rather than applied where it "seems needed".
        await server.rpc('server/invalidate', {file});

        const params = {file, contents, offset};
        if (method === 'display/completion') params.wasAutoTriggered = true;

        const started = Date.now();
        const answer = await server.rpc(method, params, true, completionDefine);
        console.log(`${label.padEnd(34)} ${describe(method, answer)}   (${Date.now() - started} ms)`);
        return answer;
    }

    console.log('--- component tag names (a) ---');
    await probe('<|            toplevel', 'display/completion', '_w', 2);
    await probe('<Butt|        prefixed', 'display/completion', 'Butt_w', 6);
    await probe('<kit.|        dotted', 'display/completion', 'kit._w', 6);
    await probe('<kit.ui.|     dotted', 'display/completion', 'kit.ui._w', 9);
    // Statics and module sub-types. Empty for a plain component class, which has neither.
    await probe('<kit.ui.Button.|  module', 'display/completion', 'kit.ui.Button._w', 16);

    console.log('\n--- hover (b) and definition (c) ---');
    await probe('hover <Button', 'display/hover', 'Button', 3);
    await probe('definition <Button', 'display/definition', 'Button', 3);

    console.log('\n--- attributes (d) ---');
    const d1 = '@:privateAccess (null : Button)._w';
    await probe('<Button |     class @props (d1)', 'display/completion', d1, d1.length);

    if (INJECT_X) {
        // An `@x` component is a plain function value: its declared arguments
        // ARE its attributes. `@state` ones are not, and the typed signature
        // cannot tell them apart -- that is why the design also reads the
        // declaration from source.
        await probe('<Row |        @x args (d2)', 'display/hover', 'Row', 2);
    }

    console.log(`\nsession: cacheBuild=${!NO_CACHE_BUILD} completionDefine=${!NO_COMPLETION_DEFINE}`);
    console.log('(see the header comment for the matrix these two flags reproduce)');

    server.kill();
}

main().catch(e => { console.error(e); process.exit(1); });
