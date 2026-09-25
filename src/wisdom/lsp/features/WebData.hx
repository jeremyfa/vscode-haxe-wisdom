package wisdom.lsp.features;

import haxe.DynamicAccess;
import haxe.Json;

using StringTools;

enum abstract WebLanguage(String) to String {
    var Html = "html";
    var Svg = "svg";
}

typedef WebTagInfo = {
    var name:String;
    var language:WebLanguage;
    var ?description:String;
    var ?url:String;
}

typedef WebAttrInfo = {
    var name:String;
    var language:WebLanguage;
    var ?description:String;
    var ?url:String;
    var ?values:Array<String>;
    var isBoolean:Bool;
    var isGlobal:Bool;
}

/** One attribute in the normalized files: description, MDN url, value set, boolean flag. */
private typedef Entry = {
    var ?d:String;
    var ?u:String;
    var ?v:String;
    var ?b:Bool;
}

private typedef TagEntry = {
    var ?d:String;
    var ?u:String;
    var a:DynamicAccess<Null<Entry>>;
}

private typedef DataFile = {
    var format:Int;
    var language:String;
    var tags:DynamicAccess<TagEntry>;
    var global:DynamicAccess<Entry>;
    var shared:DynamicAccess<Entry>;
    var values:DynamicAccess<Array<String>>;
}

/**
 * The documentation for HTML and SVG tags and attributes, read from the
 * files `scripts/update-web-data.mjs` generates into `data/`.
 *
 * This is decoration, not authority. Which tag and attribute *names* are
 * offered still comes from `wisdom.HtmlAttributes` / `SvgAttributes` -- the
 * tables the renderer validates against -- because a name Wisdom would
 * silently drop must not be suggested however well documented it is. What this
 * adds is what those tables lack: descriptions, MDN links, value sets, and
 * which attributes are boolean.
 *
 * Loading is lazy and per language, so a project that never asks about HTML
 * never reads a byte, and a project with no SVG never parses `svg.json`.
 */
class WebData {

    static inline var FORMAT = 1;

    /** Where `html.json` and `svg.json` live. Tests point this at the repo's `data/`. */
    public static var basePath(get, set):String;
    static var basePathOverride:Null<String> = null;

    public static dynamic function onLog(message:String):Void {}

    static final files:Map<String, DataFile> = [];
    static final failed:Map<String, Bool> = [];

    /// Tags

    /** HTML first, then SVG; SVG names are case-sensitive but a lowercase spelling is accepted. */
    public static function tag(name:String):Null<WebTagInfo> {

        final html = load(Html);
        if (html != null && html.tags.exists(name)) return tagInfo(name, Html, html.tags.get(name));

        final svg = load(Svg);
        if (svg != null) {
            if (svg.tags.exists(name)) return tagInfo(name, Svg, svg.tags.get(name));
            final actual = svgNameFor(svg, name);
            if (actual != null) return tagInfo(actual, Svg, svg.tags.get(actual));
        }

        return null;

    }

    /** In `svg.json` and not in `html.json`. Shared names (`a`, `script`, `style`, `title`) count as HTML. */
    public static function isSvgTag(name:String):Bool {

        final html = load(Html);
        if (html != null && html.tags.exists(name)) return false;
        final svg = load(Svg);
        return svg != null && (svg.tags.exists(name) || svgNameFor(svg, name) != null);

    }

    /// Attributes

    /**
     * The attribute as documented for this tag.
     *
     * Per-tag entry first (an SVG `null` meaning "see `shared`"), then the
     * language's shared or global set. An SVG element falls back to the HTML
     * globals last, since `class`, `style` and `id` are universal either way.
     */
    public static function attribute(tagName:String, name:String):Null<WebAttrInfo> {

        final html = load(Html);
        final svg = load(Svg);

        if (html != null && html.tags.exists(tagName)) {
            final entry = html.tags.get(tagName).a.get(name);
            if (entry != null) return attrInfo(name, Html, html, entry, false);
            final global = html.global.get(name);
            if (global != null) return attrInfo(name, Html, html, global, true);
            return null;
        }

        if (svg != null) {
            final actual = svg.tags.exists(tagName) ? tagName : svgNameFor(svg, tagName);
            if (actual != null) {
                final perTag = svg.tags.get(actual).a;
                if (perTag.exists(name)) {
                    final entry = perTag.get(name);
                    // `null` is the normalizer saying "identical everywhere": see shared.
                    final resolved = entry != null ? entry : svg.shared.get(name);
                    if (resolved != null) return attrInfo(name, Svg, svg, resolved, false);
                }
                final shared = svg.shared.get(name);
                if (shared != null) return attrInfo(name, Svg, svg, shared, false);
                if (html != null) {
                    final global = html.global.get(name);
                    if (global != null) return attrInfo(name, Html, html, global, true);
                }
            }
        }

        return null;

    }

    /** Every documented attribute of a tag: its own, then (HTML) the globals. */
    public static function attributesOf(tagName:String):Array<WebAttrInfo> {

        final out:Array<WebAttrInfo> = [];
        final seen:Map<String, Bool> = [];

        final html = load(Html);
        if (html != null && html.tags.exists(tagName)) {
            for (name => entry in html.tags.get(tagName).a) {
                seen.set(name, true);
                out.push(attrInfo(name, Html, html, entry, false));
            }
            for (name => entry in html.global) {
                if (seen.exists(name)) continue;
                out.push(attrInfo(name, Html, html, entry, true));
            }
            return out;
        }

        final svg = load(Svg);
        if (svg != null) {
            final actual = svg.tags.exists(tagName) ? tagName : svgNameFor(svg, tagName);
            if (actual != null) {
                for (name => entry in svg.tags.get(actual).a) {
                    final resolved = entry != null ? entry : svg.shared.get(name);
                    if (resolved == null) continue;
                    out.push(attrInfo(name, Svg, svg, resolved, false));
                }
            }
        }

        return out;

    }

    public static function valuesOf(tagName:String, name:String):Null<Array<String>> {

        final info = attribute(tagName, name);
        return info != null ? info.values : null;

    }

    public static function isBoolean(tagName:String, name:String):Bool {

        final info = attribute(tagName, name);
        return info != null && info.isBoolean;

    }

    /// Hover text
    //
    // The same shape VSCode's own HTML hover uses: the description, a blank
    // line, then the MDN link. No code fence: this is prose about an element,
    // not a signature.

    public static function tagHoverMarkdown(name:String):Null<String> {

        final info = tag(name);
        if (info == null || info.description == null) return null;

        var text = info.description;
        if (info.url != null) text += "\n\n[MDN Reference](" + info.url + ")";
        return text;

    }

    /**
     * Description, MDN link, and the one thing about the attribute a Wisdom
     * author needs to know that MDN will not tell them: how its value is
     * spelled here. Null when there is nothing useful to say, as VSCode does.
     */
    public static function attributeHoverMarkdown(tagName:String, name:String):Null<String> {

        final info = attribute(tagName, name);
        if (info == null) return null;

        final parts = [];
        if (info.description != null) parts.push(info.description);

        if (info.isBoolean) {
            // A quoted "false" would set the attribute; only a Bool removes it.
            parts.push('Boolean attribute: write `${name}=true`, `${name}=false` or `${name}=$${cond}`; '
                + 'any quoted string, including `"false"`, sets it.');
        }
        else if (info.values != null && info.values.length > 0) {
            final shown = info.values.length > 12 ? info.values.slice(0, 12) : info.values;
            var line = "Values: " + [for (value in shown) "`" + value + "`"].join(", ");
            if (info.values.length > 12) line += ", …";
            parts.push(line);
        }

        if (parts.length == 0) return null;

        if (info.url != null) parts.push("[MDN Reference](" + info.url + ")");
        return parts.join("\n\n");

    }

    /// Loading

    static function get_basePath():String {

        if (basePathOverride != null) return basePathOverride;
        #if (js && hxnodejs)
        // The server bundle sits at the extension root, next to `data/`.
        return js.node.Path.join(js.Node.__dirname, "data");
        #else
        return "data";
        #end

    }

    static function set_basePath(value:String):String {

        basePathOverride = value;
        // A new location means whatever was loaded no longer applies.
        files.clear();
        failed.clear();
        return value;

    }

    /**
     * Read and cache one language's file.
     *
     * A failed load is remembered so a missing or corrupt file costs one
     * lookup afterwards, and is reported once rather than on every hover.
     */
    static function load(language:WebLanguage):Null<DataFile> {

        final key:String = language;
        final cached = files.get(key);
        if (cached != null) return cached;
        if (failed.exists(key)) return null;

        final path = basePath + "/" + key + ".json";
        try {
            final parsed:DataFile = Json.parse(sys.io.File.getContent(path));
            if (parsed == null || parsed.format != FORMAT) {
                throw 'unexpected format ${parsed != null ? Std.string(parsed.format) : "null"}, wanted $FORMAT';
            }
            files.set(key, parsed);
            return parsed;
        }
        catch (e:Any) {
            failed.set(key, true);
            onLog('Could not load $path: $e -- $key documentation disabled');
            return null;
        }

    }

    /// Helpers

    /** SVG element names are camelCase; accept `lineargradient` for `linearGradient`. */
    static function svgNameFor(svg:DataFile, name:String):Null<String> {

        final lower = name.toLowerCase();
        for (candidate in svg.tags.keys()) {
            if (candidate.toLowerCase() == lower) return candidate;
        }
        return null;

    }

    static function tagInfo(name:String, language:WebLanguage, entry:TagEntry):WebTagInfo {

        return {
            name: name,
            language: language,
            description: entry.d,
            url: entry.u
        };

    }

    static function attrInfo(name:String, language:WebLanguage, file:DataFile, entry:Entry, isGlobal:Bool):WebAttrInfo {

        return {
            name: name,
            language: language,
            description: entry.d,
            url: entry.u,
            values: entry.v != null ? file.values.get(entry.v) : null,
            isBoolean: entry.b == true,
            isGlobal: isGlobal
        };

    }

}
