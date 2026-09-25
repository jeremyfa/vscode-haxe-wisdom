package wisdom.lsp.markup;

import wisdom.lsp.markup.HaxeStringLexer;

using StringTools;

typedef ComponentArgument = {
    var name:String;
    var ?type:String;
    var ?defaultValue:String;
    /**
     * Component-local reactive state, not an attribute.
     *
     * The compiler cannot tell us this: `JsonFunctionArgument` is just
     * `{name, opt, t}` with no metadata, so a `@state` argument is
     * indistinguishable from a real prop in a typed signature.
     */
    var isState:Bool;
}

/**
 * Reads a component's declaration straight from its source.
 *
 * Two jobs, both of which the display protocol cannot do:
 *
 *  - separate the `@state` arguments of an `@x` function component from its
 *    real props, since the typed signature carries no metadata;
 *  - act as the fallback for `@props` fields when the probe fails to compile.
 *
 * Deliberately a scanner and not a parser: it only ever runs on a declaration
 * the compiler has already located for us, so it can be narrow.
 */
class ComponentSourceScanner {

    /**
     * Arguments of `@x function Name(...)`, given an offset anywhere in its
     * declaration (typically the range `display/definition` returned).
     */
    public static function readXArgs(text:String, declarationOffset:Int):Array<ComponentArgument> {

        final open = text.indexOf("(", declarationOffset);
        if (open == -1) return [];

        final close = matchingParen(text, open);
        if (close == -1) return [];

        return [for (segment in splitTopLevel(text.substring(open + 1, close))) parseArgument(segment)];

    }

    /**
     * `@props` fields of a class, given an offset anywhere inside it.
     *
     * Scans to the end of the enclosing class body rather than the whole file,
     * so a second class in the same module cannot leak in.
     */
    public static function readProps(text:String, declarationOffset:Int):Array<ComponentArgument> {

        final bodyStart = text.indexOf("{", declarationOffset);
        if (bodyStart == -1) return [];
        final bodyEnd = matchingBrace(text, bodyStart);
        final limit = bodyEnd == -1 ? text.length : bodyEnd;

        final found:Array<ComponentArgument> = [];
        final pattern = ~/@props\s+(?:final|var)\s+([a-zA-Z_][a-zA-Z_0-9]*)\s*(?:\([^)]*\))?\s*(?::\s*([^;=]+?))?\s*(?:=\s*([^;]+?))?\s*;/;

        var rest = text.substring(bodyStart, limit);
        while (pattern.match(rest)) {
            found.push({
                name: pattern.matched(1),
                type: trimOrNull(pattern.matched(2)),
                defaultValue: trimOrNull(pattern.matched(3)),
                isState: false
            });
            rest = pattern.matchedRight();
        }

        return found;

    }

    /// Internals

    /** `@meta* ?? name (: Type)? (= default)?` */
    static function parseArgument(segment:String):ComponentArgument {

        var rest = segment.trim();
        var isState = false;

        // Metadata comes first and there may be several.
        while (rest.startsWith("@")) {
            final end = metadataEnd(rest);
            final name = rest.substring(1, end).split("(")[0];
            if (name == "state") isState = true;
            rest = rest.substring(end).ltrim();
        }

        if (rest.startsWith("?")) rest = rest.substr(1).ltrim();

        var name = "";
        var i = 0;
        while (i < rest.length && HaxeStringLexer.isIdentPart(rest.charCodeAt(i))) {
            name += rest.charAt(i);
            i++;
        }
        rest = rest.substr(i).ltrim();

        var type:String = null;
        var defaultValue:String = null;

        if (rest.startsWith(":")) {
            rest = rest.substr(1);
            // The type ends at a top-level `=`, which `->` must not be mistaken for.
            final equals = topLevelEquals(rest);
            if (equals == -1) {
                type = rest.trim();
                rest = "";
            }
            else {
                type = rest.substring(0, equals).trim();
                rest = rest.substr(equals + 1);
            }
        }
        else if (rest.startsWith("=")) {
            rest = rest.substr(1);
        }

        if (rest.trim() != "") defaultValue = rest.trim();

        return {name: name, type: trimOrNull(type), defaultValue: trimOrNull(defaultValue), isState: isState};

    }

    static function metadataEnd(text:String):Int {

        var i = 1;
        if (i < text.length && text.charAt(i) == ":") i++;
        while (i < text.length && (HaxeStringLexer.isIdentPart(text.charCodeAt(i)) || text.charAt(i) == ".")) i++;
        if (i < text.length && text.charAt(i) == "(") {
            final close = matchingParen(text, i);
            return close == -1 ? text.length : close + 1;
        }
        return i;

    }

    /** `=` at nesting level zero, skipping the `=` of `->` and of `==`. */
    static function topLevelEquals(text:String):Int {

        var depth = 0;
        for (i in 0...text.length) {
            final c = text.charAt(i);
            switch c {
                case "(" | "[" | "{" | "<": depth++;
                case ")" | "]" | "}" | ">": depth--;
                case "=":
                    if (depth <= 0 && text.charAt(i - 1) != "-" && text.charAt(i + 1) != "=") return i;
                case _:
            }
        }
        return -1;

    }

    /** Split on commas that are not inside brackets or a string. */
    static function splitTopLevel(text:String):Array<String> {

        final parts = [];
        var depth = 0;
        var start = 0;
        var i = 0;

        while (i < text.length) {
            final c = text.charAt(i);
            switch c {
                case "(" | "[" | "{" | "<": depth++;
                case ")" | "]" | "}" | ">": depth--;
                case "\"" | "'":
                    final quote = c;
                    i++;
                    while (i < text.length && text.charAt(i) != quote) {
                        if (text.charAt(i) == "\\") i++;
                        i++;
                    }
                case ",":
                    if (depth == 0) {
                        parts.push(text.substring(start, i));
                        start = i + 1;
                    }
                case _:
            }
            i++;
        }

        final last = text.substring(start);
        if (last.trim() != "") parts.push(last);
        return parts;

    }

    static function matchingParen(text:String, open:Int):Int {
        return matching(text, open, "(".code, ")".code);
    }

    static function matchingBrace(text:String, open:Int):Int {
        return matching(text, open, "{".code, "}".code);
    }

    static function matching(text:String, open:Int, openCode:Int, closeCode:Int):Int {

        var depth = 0;
        var i = open;
        while (i < text.length) {
            final c = text.charCodeAt(i);
            if (c == "\"".code || c == "'".code) {
                final quote = c;
                i++;
                while (i < text.length && text.charCodeAt(i) != quote) {
                    if (text.charCodeAt(i) == "\\".code) i++;
                    i++;
                }
            }
            else if (c == openCode) depth++;
            else if (c == closeCode) {
                depth--;
                if (depth == 0) return i;
            }
            i++;
        }
        return -1;

    }

    static inline function trimOrNull(value:String):String {
        return value == null || value.trim() == "" ? null : value.trim();
    }

}
