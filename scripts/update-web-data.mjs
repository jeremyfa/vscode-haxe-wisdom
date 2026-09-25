#!/usr/bin/env node
/*
 * Regenerates data/html.json, data/svg.json and data/THIRD_PARTY.md from their
 * pinned upstream sources.
 *
 * Usage:
 *   node scripts/update-web-data.mjs            # download, normalize, write
 *   node scripts/update-web-data.mjs --check    # regenerate in memory, exit 1 if data/ differs
 *   node scripts/update-web-data.mjs --offline <dir>   # read browsers.html-data.json / html.html-data.json from <dir>
 *   node scripts/update-web-data.mjs --verbose
 *
 * Why this exists: the language server documents HTML and SVG tags and
 * attributes offline, with the same text VSCode's own HTML support shows. That
 * text lives in two upstream datasets, both far larger and shaped for a
 * different consumer than we are. This script is the single, reproducible
 * step that turns them into the compact form the Haxe loader (`WebData.hx`)
 * reads. Its output is committed; the extension never fetches anything.
 *
 * Sources are pinned by version and by commit, and their sha256 is recorded in
 * the output, so a diff in data/ is always traceable to a deliberate re-pin.
 *
 * Normalized schema (one for both files):
 *   { format: 1, language: "html"|"svg", source: {...}, attribution,
 *     tags:   { name: { d?: markdown, u?: mdnUrl, a: { attr: Entry | null } } },
 *     global: { attr: Entry },      // HTML only
 *     shared: { attr: Entry },      // SVG only; a per-tag `null` means "see shared[attr]"
 *     values: { setName: [ ... ] } }
 *   Entry = { d?: markdown, u?: mdnUrl, v?: valueSetName, b?: true }
 *   `b` marks a boolean attribute (upstream valueSet "v"), which is valueless in
 *   HTML and written `disabled=true` / `disabled=${cond}` in Wisdom.
 */

import {createHash} from 'node:crypto';
import {existsSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const DATA_DIR = join(ROOT, 'data');

/// Pins

const HTML = {
    name: '@vscode/web-custom-data',
    version: '0.6.3',
    license: 'MIT',
    data: 'https://cdn.jsdelivr.net/npm/@vscode/web-custom-data@0.6.3/data/browsers.html-data.json',
    licenseUrl: 'https://cdn.jsdelivr.net/npm/@vscode/web-custom-data@0.6.3/LICENSE.md',
    offlineName: 'browsers.html-data.json',
};

const SVG_COMMIT = '3cc39fa98e434cd777f5a360588900c17e1b3619';
const SVG = {
    name: 'lishu/vscode-svg2',
    version: SVG_COMMIT,
    license: 'MIT',
    data: `https://raw.githubusercontent.com/lishu/vscode-svg2/${SVG_COMMIT}/html.html-data.json`,
    licenseUrl: `https://raw.githubusercontent.com/lishu/vscode-svg2/${SVG_COMMIT}/LICENSE`,
    offlineName: 'html.html-data.json',
};

const ATTRIBUTION = 'Element and attribute descriptions are derived from MDN Web Docs by Mozilla Contributors and are licensed under CC BY-SA 2.5 (https://creativecommons.org/licenses/by-sa/2.5/).';

/** The only SVG elements on which `fill` is the animation attribute (remove|freeze). */
const ANIMATION_ELEMENTS = new Set(['animate', 'animateColor', 'animateMotion', 'animateTransform', 'set']);

/**
 * Upstream documents these four elements with nothing but its advertising
 * trailer, so once that is stripped they would have no description at all.
 * Rather than ship an undocumented tag, give each the one sentence MDN opens with.
 */
const SVG_TAG_FALLBACKS = {
    animate: 'Animates an attribute of an element over time, interpolating between the given values.',
    animateColor: 'Animates a color attribute over time. Deprecated: use `<animate>` instead.',
    animateMotion: 'Moves an element along a motion path, given as a `path` attribute or an `<mpath>` child.',
    animateTransform: 'Animates a transformation attribute (`translate`, `scale`, `rotate`, `skewX`, `skewY`) on its target element.',
};

const SIZE_BUDGET = 400 * 1024;

/// Arguments

const argv = process.argv.slice(2);
const CHECK = argv.includes('--check');
const VERBOSE = argv.includes('--verbose');
const offlineAt = argv.indexOf('--offline');
const OFFLINE_DIR = offlineAt !== -1 ? argv[offlineAt + 1] : null;

const log = (...args) => console.log(...args);
const verbose = (...args) => { if (VERBOSE) console.log(...args); };

/// Fetching

async function fetchText(url) {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
    return await response.text();
}

async function loadSource(pin) {
    let text;
    if (OFFLINE_DIR) {
        const path = join(OFFLINE_DIR, pin.offlineName);
        text = readFileSync(path, 'utf8');
        verbose(`read ${path}`);
    } else {
        verbose(`fetch ${pin.data}`);
        text = await fetchText(pin.data);
    }
    const sha256 = createHash('sha256').update(text).digest('hex');
    return {json: JSON.parse(text), sha256};
}

async function loadLicense(pin) {
    if (OFFLINE_DIR) {
        const path = join(OFFLINE_DIR, `${pin.name.replace(/[@/]/g, '_')}.LICENSE`);
        return existsSync(path) ? readFileSync(path, 'utf8') : `(license text not available offline; see ${pin.licenseUrl})`;
    }
    return await fetchText(pin.licenseUrl);
}

/// Normalization helpers

/** Upstream descriptions are either a string or {kind, value}. */
function describe(description) {
    if (description == null) return undefined;
    if (typeof description === 'string') return description.trim() || undefined;
    if (typeof description.value === 'string') return description.value.trim() || undefined;
    return undefined;
}

/** First MDN reference url, if any. */
function reference(references) {
    if (!Array.isArray(references)) return undefined;
    const mdn = references.find(r => r && /^https?:\/\/developer\.mozilla\.org\//.test(r.url));
    return mdn ? mdn.url : undefined;
}

function sourceBlock(pin, sha256) {
    return {
        name: pin.name,
        version: pin.version,
        url: pin.data,
        sha256,
        license: pin.license,
        fetched: new Date().toISOString().slice(0, 10),
    };
}

/// HTML

function normalizeHtml(upstream, sha256) {
    const values = {};
    for (const set of upstream.valueSets || []) {
        values[set.name] = (set.values || []).map(v => v.name);
    }

    const toEntry = (attr) => {
        const entry = {};
        const d = describe(attr.description);
        if (d) entry.d = d;
        const u = reference(attr.references);
        if (u) entry.u = u;
        if (attr.valueSet === 'v') {
            entry.b = true;
        } else if (attr.valueSet) {
            if (!values[attr.valueSet]) throw new Error(`HTML: attribute ${attr.name} references unknown valueSet ${attr.valueSet}`);
            entry.v = attr.valueSet;
        }
        return entry;
    };

    const tags = {};
    for (const tag of upstream.tags || []) {
        const a = {};
        for (const attr of tag.attributes || []) a[attr.name] = toEntry(attr);
        const out = {};
        const d = describe(tag.description);
        if (d) out.d = d;
        const u = reference(tag.references);
        if (u) out.u = u;
        out.a = a;
        tags[tag.name] = out;
    }

    const global = {};
    for (const attr of upstream.globalAttributes || []) global[attr.name] = toEntry(attr);

    return {
        format: 1,
        language: 'html',
        source: sourceBlock(HTML, sha256),
        attribution: ATTRIBUTION,
        tags,
        global,
        shared: {},
        values,
    };
}

/// SVG

// Every upstream description ends with an advertising line followed by the
// MDN link. The link is the useful part, so it is lifted out rather than lost.
const TRAILER = /\s*🧧 \*Provide by SVG extension\.\*\s*(?:\[MDN References?\]\((https?:\/\/[^)\s]+)\))?\s*$/u;

function splitSvgDescription(raw) {
    let text = describe(raw);
    if (!text) return {d: undefined, u: undefined};

    let u;
    const match = text.match(TRAILER);
    if (match) {
        u = match[1];
        text = text.replace(TRAILER, '').trim();
    }

    // Belt and braces: anything the anchored regex did not catch.
    text = text
        .split('\n')
        .filter(line => !line.includes('🧧'))
        .map(line => {
            const standalone = line.match(/^\s*\[MDN References?\]\((https?:\/\/[^)\s]+)\)\s*$/);
            if (standalone) { if (!u) u = standalone[1]; return ''; }
            return line;
        })
        .join('\n')
        .trim();

    return {d: text || undefined, u};
}

function normalizeSvg(upstream, sha256) {
    // First pass: per (tag, attr) entries with the `fill` correction applied.
    const perTag = new Map();     // tag -> Map(attr -> {d, u, values})
    const tags = {};

    for (const tag of upstream.tags || []) {
        const {d: stripped, u} = splitSvgDescription(tag.description);
        const d = stripped || SVG_TAG_FALLBACKS[tag.name];
        const out = {};
        if (d) out.d = d;
        if (u) out.u = u;
        out.a = {};
        tags[tag.name] = out;

        const attrs = new Map();
        for (const attr of tag.attributes || []) {
            const desc = splitSvgDescription(attr.description);
            let vals = Array.isArray(attr.values) && attr.values.length > 0 ? attr.values.map(v => v.name) : undefined;
            // Upstream gives every element the animation `fill` (remove|freeze);
            // on a shape it is the paint attribute, which has no fixed value set.
            if (attr.name === 'fill' && !ANIMATION_ELEMENTS.has(tag.name)) vals = undefined;
            attrs.set(attr.name, {d: desc.d, u: desc.u, values: vals});
        }
        perTag.set(tag.name, attrs);
    }

    // Second pass: an attribute whose (description, url, values) is identical
    // on every element it appears on goes to `shared`; the rest stay inline.
    const variants = new Map();   // attr -> Map(key -> entry)
    for (const attrs of perTag.values()) {
        for (const [name, entry] of attrs) {
            const key = JSON.stringify([entry.d, entry.u, entry.values]);
            if (!variants.has(name)) variants.set(name, new Map());
            variants.get(name).set(key, entry);
        }
    }

    const shared = {};
    const values = {};
    const multi = [];

    const toEntry = (entry, valueSetName) => {
        const out = {};
        if (entry.d) out.d = entry.d;
        if (entry.u) out.u = entry.u;
        if (entry.values) {
            values[valueSetName] = entry.values;
            out.v = valueSetName;
        }
        return out;
    };

    for (const [name, byKey] of variants) {
        if (byKey.size === 1) {
            shared[name] = toEntry([...byKey.values()][0], name);
        } else {
            multi.push(name);
        }
    }

    for (const [tagName, attrs] of perTag) {
        for (const [name, entry] of attrs) {
            if (variants.get(name).size === 1) {
                tags[tagName].a[name] = null;
            } else {
                tags[tagName].a[name] = toEntry(entry, `${name}@${tagName}`);
            }
        }
    }

    return {
        data: {
            format: 1,
            language: 'svg',
            source: sourceBlock(SVG, sha256),
            attribution: ATTRIBUTION,
            tags,
            global: {},
            shared,
            values,
        },
        multi: multi.sort(),
    };
}

/// Validation

function validate(data, label) {
    const problems = [];
    const check = (ok, message) => { if (!ok) problems.push(`${label}: ${message}`); };

    const entryOk = (entry, where) => {
        if (entry == null) return;
        check(!(entry.b && entry.v), `${where} has both b and v`);
        if (entry.v) check(Array.isArray(data.values[entry.v]), `${where} references unknown value set ${entry.v}`);
        if (entry.u) check(entry.u.startsWith('https://developer.mozilla.org/'), `${where} url is not MDN: ${entry.u}`);
        if (entry.d) {
            check(!entry.d.includes('🧧'), `${where} still carries the advert marker`);
            check(!entry.d.includes('Provide by SVG extension'), `${where} still carries the advert text`);
        }
    };

    for (const [name, tag] of Object.entries(data.tags)) {
        check(typeof tag.d === 'string' && tag.d.length > 0, `tag <${name}> has no description`);
        if (tag.u) check(tag.u.startsWith('https://developer.mozilla.org/'), `tag <${name}> url is not MDN`);
        if (tag.d) check(!tag.d.includes('🧧'), `tag <${name}> still carries the advert marker`);
        for (const [attr, entry] of Object.entries(tag.a)) {
            if (entry === null) check(data.shared[attr] !== undefined, `<${name} ${attr}> points to a missing shared entry`);
            else entryOk(entry, `<${name} ${attr}>`);
        }
    }
    for (const [attr, entry] of Object.entries(data.global)) entryOk(entry, `global ${attr}`);
    for (const [attr, entry] of Object.entries(data.shared)) entryOk(entry, `shared ${attr}`);

    if (problems.length > 0) {
        throw new Error(`validation failed:\n  ${problems.slice(0, 20).join('\n  ')}${problems.length > 20 ? `\n  ... ${problems.length - 20} more` : ''}`);
    }
}

/// Output

function serialize(data) {
    const text = JSON.stringify(data);
    if (Buffer.byteLength(text) > SIZE_BUDGET) {
        throw new Error(`${data.language}.json is ${Buffer.byteLength(text)} bytes, over the ${SIZE_BUDGET} byte budget`);
    }
    return text;
}

function stats(data) {
    const tags = Object.keys(data.tags).length;
    let tagAttrs = 0;
    let inline = 0;
    for (const tag of Object.values(data.tags)) {
        for (const entry of Object.values(tag.a)) {
            tagAttrs++;
            if (entry !== null) inline++;
        }
    }
    return {
        tags,
        tagAttrs,
        inline,
        shared: Object.keys(data.shared).length,
        global: Object.keys(data.global).length,
        valueSets: Object.keys(data.values).length,
        bytes: Buffer.byteLength(JSON.stringify(data)),
    };
}

function thirdPartyNotice(entries) {
    const sections = entries.map(({pin, sha256, license}) => [
        `## ${pin.name}`,
        '',
        `- Version: ${pin.version}`,
        `- Source: ${pin.data}`,
        `- SHA-256 of the downloaded file: ${sha256}`,
        `- License: ${pin.license}`,
        '',
        '```',
        license.trim(),
        '```',
        '',
    ].join('\n'));

    return [
        '# Third-party data',
        '',
        'The files in this directory are generated by `scripts/update-web-data.mjs` from the',
        'sources below. Do not edit them by hand; re-run the script instead.',
        '',
        ...sections,
        '## Attribution',
        '',
        ATTRIBUTION,
        '',
    ].join('\n');
}

/** Same content, ignoring the fetch date, which changes on every run. */
function sameData(a, b) {
    const strip = (data) => {
        const copy = JSON.parse(JSON.stringify(data));
        if (copy.source) delete copy.source.fetched;
        return JSON.stringify(copy);
    };
    return strip(a) === strip(b);
}

/// Main

async function main() {
    const html = await loadSource(HTML);
    const svg = await loadSource(SVG);

    const htmlData = normalizeHtml(html.json, html.sha256);
    const {data: svgData, multi} = normalizeSvg(svg.json, svg.sha256);

    validate(htmlData, 'html');
    validate(svgData, 'svg');

    const htmlStats = stats(htmlData);
    const svgStats = stats(svgData);
    log(`html: ${htmlStats.tags} tags, ${htmlStats.tagAttrs} tag attributes, ${htmlStats.global} global attributes, ${htmlStats.valueSets} value sets, ${htmlStats.bytes} bytes`);
    log(`svg : ${svgStats.tags} tags, ${svgStats.tagAttrs} tag attributes (${svgStats.shared} shared, ${svgStats.inline} inline), ${svgStats.valueSets} value sets, ${svgStats.bytes} bytes`);
    log(`svg : attributes kept per element because they differ between elements: ${multi.join(', ') || '(none)'}`);

    // What the normalizer is designed around; a change here means upstream moved.
    if (multi.join(',') !== 'fill,type') {
        log(`warning: expected the per-element attributes to be exactly "fill, type"`);
    }

    const htmlText = serialize(htmlData);
    const svgText = serialize(svgData);

    if (CHECK) {
        const current = (name) => {
            const path = join(DATA_DIR, name);
            return existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) : null;
        };
        const htmlSame = current('html.json') && sameData(current('html.json'), htmlData);
        const svgSame = current('svg.json') && sameData(current('svg.json'), svgData);
        if (!htmlSame || !svgSame) {
            log(`check: data/ is out of date (${!htmlSame ? 'html.json ' : ''}${!svgSame ? 'svg.json' : ''})`);
            process.exit(1);
        }
        log('check: data/ is up to date');
        return;
    }

    const [htmlLicense, svgLicense] = await Promise.all([loadLicense(HTML), loadLicense(SVG)]);

    mkdirSync(DATA_DIR, {recursive: true});
    writeFileSync(join(DATA_DIR, 'html.json'), htmlText);
    writeFileSync(join(DATA_DIR, 'svg.json'), svgText);
    writeFileSync(join(DATA_DIR, 'THIRD_PARTY.md'), thirdPartyNotice([
        {pin: HTML, sha256: html.sha256, license: htmlLicense},
        {pin: SVG, sha256: svg.sha256, license: svgLicense},
    ]));
    log(`wrote ${DATA_DIR}/html.json, svg.json, THIRD_PARTY.md`);
}

main().catch(error => {
    console.error(error.message || error);
    process.exit(1);
});
