#!/usr/bin/env node
/*
 * Checks the `tailwindCSS.experimental.classRegex` entries the extension
 * writes, using JavaScript regex semantics -- the ones the Tailwind language
 * server actually uses -- against real Wisdom markup shapes.
 *
 * Haxe's EReg on the eval target is PCRE, so a Haxe-side test would prove the
 * wrong thing. The patterns are read from the compiled source of
 * `TailwindSettings` so this cannot drift from what gets written.
 *
 * Usage: node scripts/tailwind-regex-check.mjs
 */

import {readFileSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = readFileSync(join(ROOT, 'src/wisdom/lsp/TailwindSettings.hx'), 'utf8');

/** Read a `public static inline var NAME = "..."` string literal out of the Haxe source. */
function haxeString(name) {
    const match = source.match(new RegExp(`inline var ${name} = "((?:[^"\\\\]|\\\\.)*)";`));
    if (!match) throw new Error(`${name} not found in TailwindSettings.hx`);
    // Undo Haxe's double-quoted escaping: \\ -> \, \" -> "
    return match[1].replace(/\\(.)/g, '$1');
}

const CONTAINER = haxeString('CONTAINER_REGEX');
const SINGLE = haxeString('SINGLE_QUOTED_REGEX');
const DOUBLE = haxeString('DOUBLE_QUOTED_REGEX');

/**
 * Tailwind's two-level matching, as the server does it: every container match,
 * then every inner match within the captured group.
 */
function classLists(text) {
    const lists = [];
    const container = new RegExp(CONTAINER, 'g');
    for (const outer of text.matchAll(container)) {
        const body = outer[1];
        for (const inner of [SINGLE, DOUBLE]) {
            for (const match of body.matchAll(new RegExp(inner, 'g'))) lists.push(match[1]);
        }
    }
    return lists;
}

const cases = [
    // The Switch.hx shape: a base string plus a ternary.
    {
        text: `class=\${'relative w-11 h-6 rounded-full ' + (value ? 'bg-t-accent' : 'bg-t-surface-secondary')}`,
        expect: ['relative w-11 h-6 rounded-full ', 'bg-t-accent', 'bg-t-surface-secondary'],
    },
    // Wisdom's alias, with double quotes inside the expression.
    {
        text: `classes=\${["flex", "gap-2"]}`,
        expect: ['flex', 'gap-2'],
    },
    // React-style alias.
    {
        text: `className=\${cond ? 'a' : 'b'}`,
        expect: ['a', 'b'],
    },
    // One level of nested braces: an object literal, which has no class lists.
    {
        text: `class=\${{a: 1}}`,
        expect: [],
    },
    // Two attributes on one tag, both expression-valued.
    {
        text: `<div class=\${'p-2'} title=\${x} classes=\${'m-1'}>`,
        expect: ['p-2', 'm-1'],
    },
    // Plain `class="..."` is Tailwind's own business (via includeLanguages), not these regexes.
    {
        text: `<div class="flex items-center">`,
        expect: [],
    },
    // Not a class attribute at all.
    {
        text: `subclass=\${'nope'} dataclass=\${'nope'}`,
        expect: [],
    },
];

let failures = 0;
for (const {text, expect} of cases) {
    const got = classLists(text);
    const ok = JSON.stringify(got) === JSON.stringify(expect);
    if (!ok) failures++;
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${text}`);
    if (!ok) console.log(`       expected ${JSON.stringify(expect)}\n       got      ${JSON.stringify(got)}`);
}

// The exact JSON the extension writes, for eyeballing against .vscode/settings.json.
console.log('\nclassRegex entries as written:');
console.log(JSON.stringify([[CONTAINER, SINGLE], [CONTAINER, DOUBLE]], null, 2));

if (failures > 0) {
    console.log(`\n${failures}/${cases.length} cases failed`);
    process.exit(1);
}
console.log(`\nall ${cases.length} cases passed`);
