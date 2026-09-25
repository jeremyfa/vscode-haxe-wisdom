package wisdom.lsp.markup;

import wisdom.lsp.markup.MarkupTypes;

/**
 * Pass A: find every `'<>...'` literal and every interpolation inside one.
 *
 * This follows the **Haxe lexer**, not the Wisdom grammar, and it is the only
 * thing that decides where a markup region starts and ends. Keeping that
 * decision here is what makes pass B free to be as error-tolerant as it likes:
 * however confused it gets about tags, it can never run past a region boundary.
 *
 * The rule that matters most: inside `${...}` Haxe reads **code** again, so a
 * nested `'<>...'` there is a nested region. That is how markup inside a
 * `<foreach>` lambda is actually written -- unescaped -- and mishandling it is
 * exactly why `WisdomFoldingProvider` never worked.
 */
class HaxeStringLexer {

    public static function scan(text:String):ScanResult {

        final lexer = new HaxeStringLexer(text);
        lexer.scanCode(null, false);

        lexer.regions.sort((a, b) -> a.quoteStart - b.quoteStart);

        return {
            text: text,
            regions: lexer.regions,
            topRegions: [for (region in lexer.regions) if (region.depth == 0) region]
        };

    }

    final text:String;
    final length:Int;
    final regions:Array<MarkupRegion> = [];

    var i:Int = 0;

    function new(text:String) {
        this.text = text;
        this.length = text.length;
    }

    /**
     * Scan Haxe code.
     *
     * When `untilCloseBrace`, the opening `{` has already been consumed and we
     * stop on the matching `}`, leaving `i` on it.
     */
    function scanCode(enclosing:Null<MarkupRegion>, untilCloseBrace:Bool):Void {

        var depth = 0;

        while (i < length) {
            final c = text.charCodeAt(i);

            if (c == '/'.code && i + 1 < length) {
                final next = text.charCodeAt(i + 1);
                if (next == '/'.code) { skipLineComment(); continue; }
                if (next == '*'.code) { skipBlockComment(); continue; }
                i++;
                continue;
            }

            if (c == '~'.code && i + 1 < length && text.charCodeAt(i + 1) == '/'.code) {
                skipRegexLiteral();
                continue;
            }

            if (c == '"'.code) { skipDoubleQuoted(); continue; }

            if (c == "'".code) { scanSingleQuoted(enclosing); continue; }

            if (untilCloseBrace) {
                if (c == '{'.code) { depth++; i++; continue; }
                if (c == '}'.code) {
                    if (depth == 0) return;
                    depth--;
                    i++;
                    continue;
                }
            }

            i++;
        }

    }

    /**
     * Scan a single-quoted Haxe string, starting on its opening quote.
     *
     * Records it as a markup region when it opens with `<>`. Plain single-quoted
     * strings still have to be walked, because their interpolations may contain
     * markup of their own.
     */
    function scanSingleQuoted(enclosing:Null<MarkupRegion>):Void {

        final quoteStart = i;
        i++;

        final isMarkup = i + 1 < length
            && text.charCodeAt(i) == '<'.code
            && text.charCodeAt(i + 1) == '>'.code;

        var region:MarkupRegion = null;
        if (isMarkup) {
            region = {
                quoteStart: quoteStart,
                contentStart: i + 2,
                contentEnd: length,
                terminated: false,
                depth: enclosing == null ? 0 : enclosing.depth + 1,
                parent: enclosing,
                children: [],
                interps: [],
                roots: [],
                tags: [],
                comments: [],
                issues: [],
                scanned: false
            };
            regions.push(region);
            if (enclosing != null) enclosing.children.push(region);
            i += 2;
        }

        // A literal's interpolations belong to that literal and to nothing else.
        //
        // In particular a plain string nested inside a markup interpolation --
        // `style=${{ padding: '${n}px' }}` -- must NOT donate its `${n}` to the
        // enclosing region: that would insert a span sitting inside another
        // span, and out of source order, since the outer one is only recorded
        // once its whole body has been scanned. `contextAt` already answers
        // InHaxeExpr for those positions through the outer interpolation.
        final owner = region;

        while (i < length) {
            final c = text.charCodeAt(i);

            if (c == '\\'.code) {
                i += 2;
                continue;
            }

            if (c == '$'.code) {
                // `$$` is an escaped dollar, two characters, no interpolation.
                if (i + 1 < length && text.charCodeAt(i + 1) == '$'.code) {
                    i += 2;
                    continue;
                }
                final interp = scanInterpolation(owner);
                if (interp != null) {
                    if (owner != null) owner.interps.push(interp);
                    continue;
                }
                // A `$` followed by nothing interpolatable is just a character.
                i++;
                continue;
            }

            if (c == "'".code) {
                if (region != null) {
                    region.contentEnd = i;
                    region.terminated = true;
                }
                i++;
                return;
            }

            i++;
        }

        // Unterminated literal: the region runs to the end of the document.
        if (region != null) {
            region.contentEnd = length;
            region.terminated = false;
        }

    }

    /**
     * Scan `$ident` or `${expr}`, starting on the `$`.
     * Returns null when the `$` does not open an interpolation.
     */
    function scanInterpolation(enclosing:Null<MarkupRegion>):Null<InterpSpan> {

        final start = i;

        if (i + 1 < length && text.charCodeAt(i + 1) == '{'.code) {
            i += 2;
            final exprStart = i;
            scanCode(enclosing, true);
            final exprEnd = i;
            final balanced = i < length && text.charCodeAt(i) == '}'.code;
            if (balanced) i++;
            return {
                start: start,
                exprStart: exprStart,
                exprEnd: exprEnd,
                end: i,
                braced: true,
                balanced: balanced
            };
        }

        if (i + 1 < length && isIdentStart(text.charCodeAt(i + 1))) {
            i++;
            final exprStart = i;
            while (i < length && isIdentPart(text.charCodeAt(i))) i++;
            return {
                start: start,
                exprStart: exprStart,
                exprEnd: i,
                end: i,
                braced: false,
                balanced: true
            };
        }

        return null;

    }

    function skipDoubleQuoted():Void {

        i++;
        while (i < length) {
            final c = text.charCodeAt(i);
            // Haxe does not interpolate double-quoted strings.
            if (c == '\\'.code) { i += 2; continue; }
            if (c == '"'.code) { i++; return; }
            i++;
        }

    }

    function skipRegexLiteral():Void {

        i += 2; // `~/`
        while (i < length) {
            final c = text.charCodeAt(i);
            if (c == '\\'.code) { i += 2; continue; }
            if (c == '/'.code) { i++; break; }
            if (c == '\n'.code) return; // unterminated; do not swallow the rest of the file
            i++;
        }
        // Trailing flags
        while (i < length && isIdentPart(text.charCodeAt(i))) i++;

    }

    function skipLineComment():Void {

        i += 2;
        while (i < length && text.charCodeAt(i) != '\n'.code) i++;

    }

    function skipBlockComment():Void {

        i += 2;
        while (i + 1 < length) {
            if (text.charCodeAt(i) == '*'.code && text.charCodeAt(i + 1) == '/'.code) {
                i += 2;
                return;
            }
            i++;
        }
        i = length;

    }

    public static inline function isIdentStart(c:Int):Bool {
        return (c >= 'a'.code && c <= 'z'.code)
            || (c >= 'A'.code && c <= 'Z'.code)
            || c == '_'.code;
    }

    public static inline function isIdentPart(c:Int):Bool {
        return isIdentStart(c) || (c >= '0'.code && c <= '9'.code);
    }

}
