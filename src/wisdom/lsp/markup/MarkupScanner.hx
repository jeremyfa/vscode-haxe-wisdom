package wisdom.lsp.markup;

import wisdom.lsp.markup.MarkupTypes;

using StringTools;

/**
 * Pass B: the Wisdom grammar, over the content of one region.
 *
 * Mirrors `wisdom.MarkupToVDom` -- same character dispatch, same regexes -- but
 * inverts its contract. `MarkupToVDom` is total on valid input and `fail()`s at
 * the first problem; this is partial on **invalid** input and must never throw,
 * because completion is by definition asked for on a buffer that does not parse
 * (`<Butt` has no `>`, no closing tag, and often no closing quote yet).
 *
 * Every interpolation found by pass A is an opaque atom here: the Wisdom
 * grammar never looks inside `${...}`.
 */
class MarkupScanner {

    /** Tags that are Wisdom control flow rather than elements or components. */
    static final CONTROL_TAGS:Map<String, ControlKind> = [
        "if" => CIf, "elseif" => CElseIf, "else" => CElse,
        "switch" => CSwitch, "case" => CCase, "default" => CDefault,
        "foreach" => CForeach, "key" => CKey
    ];

    // Copied verbatim from MarkupToVDom.hx:72-88 so the two files stay diffable.
    static final RE_TAG_COMPONENT = ~/^((?:[a-z][a-zA-Z0-9_]*\.)*)?(?:(?:([A-Z][a-zA-Z0-9_]*)(\.))*)?([A-Z][a-zA-Z_0-9]*)$/;

    public static function scan(text:String):ScanResult {

        final result = HaxeStringLexer.scan(text);
        for (region in result.regions) {
            new MarkupScanner(text, region).run();
        }
        return result;

    }

    /// Queries

    /**
     * Innermost region containing `offset`, or null.
     *
     * Regions are sorted by `quoteStart` and a nested region always starts
     * after its parent, so the last match is the innermost one.
     */
    public static function regionAt(scan:ScanResult, offset:Int):Null<MarkupRegion> {

        var found:MarkupRegion = null;
        for (region in scan.regions) {
            if (region.quoteStart > offset) break;
            if (offset >= region.contentStart && offset <= region.contentEnd) found = region;
        }
        return found;

    }

    public static function outermost(region:MarkupRegion):MarkupRegion {

        var current = region;
        while (current.parent != null) current = current.parent;
        return current;

    }

    /**
     * The open tags enclosing `offset`, outermost first.
     *
     * Drives the closing-tag suggestion and the contextual filtering of
     * `<elseif>` / `<else>` / `<case>` / `<default>`.
     */
    public static function tagStackAt(scan:ScanResult, offset:Int):Array<MarkupTag> {

        final region = regionAt(scan, offset);
        if (region == null) return [];

        final stack = [];
        var candidates = region.roots;

        while (true) {
            // Last match, not first: an unclosed tag runs to the end of the
            // region, so it overlaps every sibling after it.
            var found:MarkupTag = null;
            for (tag in candidates) {
                if (tag.closing || tag.selfClosing || tag.tagEnd == -1) continue;
                final contentEnd = tag.closeStart != -1 ? tag.closeStart : region.contentEnd;
                if (offset >= tag.tagEnd && offset <= contentEnd) found = tag;
            }
            if (found == null) break;
            stack.push(found);
            candidates = found.children;
        }

        return stack;

    }

    /**
     * What is at `offset`, and therefore whether we answer at all.
     */
    public static function contextAt(scan:ScanResult, offset:Int):CursorContext {

        final region = regionAt(scan, offset);
        if (region == null) return OutsideMarkup;

        // Checked before anything else: inside an interpolation the compiler
        // sees ordinary Haxe, so vshaxe already answers and we must not.
        for (interp in region.interps) {
            if (interp.start > offset) break;
            if (offset >= interp.exprStart && offset <= interp.exprEnd) {
                return InHaxeExpr(region, interp);
            }
        }

        for (comment in region.comments) {
            if (comment.start > offset) break;
            if (offset > comment.start && offset < comment.end) {
                return InComment(region, comment.kind);
            }
        }

        final tag = tagAt(region, offset);
        if (tag == null) return InText(region, innermostOpenTag(scan, offset));

        // On the tag name (or right after `<` / `</`, where the name will go).
        if (offset >= tag.nameStart && offset <= tag.nameEnd) {
            return InOpenTagName(
                region, tag,
                scan.text.substring(tag.nameStart, offset), tag.nameStart,
                tag.closing
            );
        }

        if (tag.closing) return InText(region, innermostOpenTag(scan, offset));

        for (attr in tag.attrs) {
            if (offset >= attr.nameStart && offset <= attr.nameEnd) {
                return InAttrName(region, tag, scan.text.substring(attr.nameStart, offset), attr.nameStart, usedAttrs(tag, attr));
            }
            if (attr.valueKind == VDoubleQuoted && attr.valueStart != -1
                && offset > attr.valueStart && offset < attr.valueEnd) {
                return InAttrStringValue(region, tag, attr);
            }
        }

        // Anywhere else inside the tag: whitespace between attributes, which is
        // where a new attribute name would be typed.
        return InAttrName(region, tag, "", offset, usedAttrs(tag, null));

    }

    static function usedAttrs(tag:MarkupTag, except:Null<MarkupAttr>):Array<String> {

        final used = [];
        for (attr in tag.attrs) {
            if (attr == except) continue;
            // `if` and `unless` may legitimately repeat (MarkupToVDom.hx:487).
            if (attr.name == "if" || attr.name == "unless") continue;
            used.push(attr.name);
        }
        return used;

    }

    static function innermostOpenTag(scan:ScanResult, offset:Int):Null<MarkupTag> {

        final stack = tagStackAt(scan, offset);
        return stack.length > 0 ? stack[stack.length - 1] : null;

    }

    /** The tag whose `<...>` span contains `offset`. */
    static function tagAt(region:MarkupRegion, offset:Int):Null<MarkupTag> {

        // Unterminated tags run to the end of the region and can therefore
        // overlap, so keep the last (innermost) match rather than the first.
        var found:MarkupTag = null;
        for (tag in region.tags) {
            if (tag.tagStart > offset) break;
            final end = tag.tagEnd != -1 ? tag.tagEnd : region.contentEnd;
            // `<` itself is not "in" the tag; the first name position is.
            if (offset > tag.tagStart && offset <= end) found = tag;
        }
        return found;

    }

    /// Scanning

    final text:String;
    final region:MarkupRegion;
    final contentEnd:Int;

    var i:Int;
    var interpIndex:Int = 0;
    var stack:Array<MarkupTag> = [];

    function new(text:String, region:MarkupRegion) {
        this.text = text;
        this.region = region;
        this.contentEnd = region.contentEnd;
        this.i = region.contentStart;
    }

    function run():Void {

        while (i < contentEnd) {

            final interp = interpAt(i);
            if (interp != null) { i = interp.end; continue; }

            final c = text.charCodeAt(i);

            if (c == '\\'.code) { i += 2; continue; }

            if (c == '<'.code) {
                if (startsWith("<!--")) { skipMarkupComment(); continue; }
                final next = i + 1 < contentEnd ? text.charCodeAt(i + 1) : 0;
                if (next == '/'.code) { parseCloseTag(); continue; }
                // Also for a `<` with nothing usable after it: that is exactly
                // "the user just typed `<`", the case completion exists for.
                parseOpenTag();
                continue;
            }

            if (c == '/'.code && i + 1 < contentEnd) {
                final next = text.charCodeAt(i + 1);
                if (next == '/'.code) { skipLineComment(); continue; }
                if (next == '*'.code) { skipBlockComment(); continue; }
            }

            if (c == '>'.code) {
                issue(i, "Unexpected '>'");
                i++;
                continue;
            }

            i++;
        }

        region.scanned = true;

    }

    function parseOpenTag():Void {

        final tagStart = i;
        i++; // `<`

        final nameStart = i;
        while (i < contentEnd && isTagNameChar(text.charCodeAt(i))) i++;
        final nameEnd = i;
        final name = text.substring(nameStart, nameEnd);
        final kind = classify(name);

        // `<elseif>` / `<else>` and `<case>` / `<default>` continue the branch
        // before them rather than nesting inside it. This has to happen before
        // the tag is built, since that is when its parent is decided.
        switch kind {
            case Control(CElseIf) | Control(CElse): popBranch([CIf, CElseIf, CElse], tagStart);
            case Control(CCase) | Control(CDefault): popBranch([CCase, CDefault], tagStart);
            case _:
        }

        final tag:MarkupTag = {
            kind: kind,
            name: name,
            nameStart: nameStart,
            nameEnd: nameEnd,
            tagStart: tagStart,
            tagEnd: -1,
            closeStart: -1,
            selfClosing: false,
            closing: false,
            attrs: [],
            positional: [],
            children: [],
            parent: stack.length > 0 ? stack[stack.length - 1] : null,
            region: region
        };
        attach(tag);

        parseTagBody(tag);

        if (tag.tagEnd != -1 && !tag.selfClosing) stack.push(tag);

    }

    function parseTagBody(tag:MarkupTag):Void {

        while (i < contentEnd) {

            final interp = interpAt(i);
            if (interp != null) {
                // A `$`/`${}` with no attribute name in front of it is a
                // positional value: `<if ${c}>`, `<foreach ${a} ${f}>`.
                tag.positional.push(interp);
                i = interp.end;
                continue;
            }

            final c = text.charCodeAt(i);

            if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code) { i++; continue; }

            // Comments are legal inside a tag (MarkupToVDom.hx:462-483).
            if (c == '/'.code && i + 1 < contentEnd && text.charCodeAt(i + 1) == '/'.code) { skipLineComment(); continue; }
            if (c == '/'.code && i + 1 < contentEnd && text.charCodeAt(i + 1) == '*'.code) { skipBlockComment(); continue; }

            if (c == '/'.code && i + 1 < contentEnd && text.charCodeAt(i + 1) == '>'.code) {
                i += 2;
                tag.selfClosing = true;
                tag.tagEnd = i;
                return;
            }

            if (c == '>'.code) {
                i++;
                tag.tagEnd = i;
                return;
            }

            // Recovery: a new tag started, so this one was never closed. Leave
            // `<` for the main loop rather than consuming it.
            if (c == '<'.code) {
                issue(i, 'Unterminated <${tag.name}>');
                return;
            }

            if (c == '\\'.code) { i += 2; continue; }

            if (c == '"'.code) { skipAttrString(); continue; }

            // Bare literal values -- `<case 3>`, `<case 0xFF>`, `<case true>`,
            // `<case _>`, `<case null>` -- are positional values to
            // MarkupToVDom, not attributes. Nothing to record about them.
            if (isDigit(c) || (c == '.'.code && i + 1 < contentEnd && isDigit(text.charCodeAt(i + 1)))) {
                skipNumber();
                continue;
            }

            if (HaxeStringLexer.isIdentStart(c)) {
                final word = peekIdent();
                if (word == "true" || word == "false" || word == "null" || word == "_") {
                    i += word.length;
                    continue;
                }
                parseAttr(tag);
                continue;
            }

            issue(i, 'Unexpected "${text.charAt(i)}" in <${tag.name}>');
            i++;
        }

        // Ran into the end of the region with the tag still open.
        issue(contentEnd, 'Unterminated <${tag.name}>');

    }

    function parseAttr(tag:MarkupTag):Void {

        final nameStart = i;
        while (i < contentEnd && isAttrNameChar(text.charCodeAt(i))) i++;
        final nameEnd = i;

        final attr:MarkupAttr = {
            name: text.substring(nameStart, nameEnd),
            nameStart: nameStart,
            nameEnd: nameEnd,
            valueKind: VNone,
            valueStart: -1,
            valueEnd: -1
        };
        tag.attrs.push(attr);

        final afterName = i;
        skipSpaces();

        var hasEquals = false;
        if (i < contentEnd && text.charCodeAt(i) == '='.code) {
            hasEquals = true;
            i++;
            skipSpaces();
        }

        if (i >= contentEnd) return;

        final interp = interpAt(i);
        if (interp != null) {
            attr.valueKind = interp.braced ? VDollarBraced : VDollarIdent;
            attr.valueStart = interp.start;
            attr.valueEnd = interp.end;
            i = interp.end;
            return;
        }

        final c = text.charCodeAt(i);

        if (c == '"'.code) {
            attr.valueKind = VDoubleQuoted;
            attr.valueStart = i;
            skipAttrString();
            attr.valueEnd = i;
            return;
        }

        if (hasEquals && c != '>'.code && c != '/'.code && c != '<'.code) {
            attr.valueKind = VLiteral;
            attr.valueStart = i;
            while (i < contentEnd && !isSpace(text.charCodeAt(i))
                   && text.charCodeAt(i) != '>'.code && text.charCodeAt(i) != '/'.code) i++;
            attr.valueEnd = i;
            return;
        }

        // No value: rewind so the next attribute name is seen by the body loop.
        i = afterName;

    }

    function parseCloseTag():Void {

        final tagStart = i;
        i += 2; // `</`

        final nameStart = i;
        // RE_TAG_CLOSE allows no dots, unlike an opening tag.
        while (i < contentEnd && HaxeStringLexer.isIdentPart(text.charCodeAt(i))) i++;
        final nameEnd = i;
        final name = text.substring(nameStart, nameEnd);

        skipSpaces();
        var tagEnd = -1;
        if (i < contentEnd && text.charCodeAt(i) == '>'.code) {
            i++;
            tagEnd = i;
        }

        final tag:MarkupTag = {
            kind: classify(name),
            name: name,
            nameStart: nameStart,
            nameEnd: nameEnd,
            tagStart: tagStart,
            tagEnd: tagEnd,
            closeStart: -1,
            selfClosing: false,
            closing: true,
            attrs: [],
            positional: [],
            children: [],
            parent: stack.length > 0 ? stack[stack.length - 1] : null,
            region: region
        };
        region.tags.push(tag);

        closeMatching(name, tagStart);

    }

    /**
     * Pop the stack down to the tag this closing tag ends.
     *
     * Matching by name rather than requiring strict nesting: on a buffer being
     * edited, an unclosed tag in between is the norm, and refusing to match
     * would lose the whole enclosing structure.
     */
    function closeMatching(name:String, closeStart:Int):Void {

        final control = CONTROL_TAGS.get(name);

        var index = -1;
        var n = stack.length - 1;
        while (n >= 0) {
            final candidate = stack[n];
            if (candidate.name == name) { index = n; break; }
            // `</if>` also closes the branch it ended on; same for `</switch>`.
            if (control == CIf) {
                switch candidate.kind {
                    case Control(CIf) | Control(CElseIf) | Control(CElse): index = n;
                    case _:
                }
                if (index != -1) break;
            }
            else if (control == CSwitch) {
                switch candidate.kind {
                    case Control(CCase) | Control(CDefault): // keep looking for the switch
                    case _:
                }
            }
            n--;
        }

        if (index == -1) {
            issue(closeStart, 'Unexpected </${name}>');
            return;
        }

        stack[index].closeStart = closeStart;
        while (stack.length > index) stack.pop();

    }

    /**
     * End the branch that the tag starting at `nextTagStart` continues.
     *
     * The previous branch has no closing tag of its own -- `</if>` closes the
     * whole chain -- so its content ends exactly where the next branch begins.
     */
    function popBranch(kinds:Array<ControlKind>, nextTagStart:Int):Void {

        if (stack.length == 0) return;
        final top = stack[stack.length - 1];
        switch top.kind {
            case Control(k) if (kinds.indexOf(k) != -1):
                if (top.closeStart == -1) top.closeStart = nextTagStart;
                stack.pop();
            case _:
        }

    }

    function attach(tag:MarkupTag):Void {

        region.tags.push(tag);
        if (tag.parent != null) tag.parent.children.push(tag);
        else region.roots.push(tag);

    }

    function classify(name:String):MarkupTagKind {

        final control = CONTROL_TAGS.get(name);
        if (control != null) return Control(control);
        if (name.length == 0) return Unknown;
        if (RE_TAG_COMPONENT.match(name)) return Component;
        final first = name.charCodeAt(0);
        if (first >= 'a'.code && first <= 'z'.code) return Html;
        return Unknown;

    }

    /// Helpers

    /**
     * The interpolation starting at `offset`, if any.
     *
     * Scanning only ever moves forward, so a cursor into the sorted list is
     * enough; no search needed.
     */
    function interpAt(offset:Int):Null<InterpSpan> {

        final interps = region.interps;
        while (interpIndex < interps.length && interps[interpIndex].end <= offset) interpIndex++;
        if (interpIndex < interps.length && interps[interpIndex].start == offset) return interps[interpIndex];
        return null;

    }

    inline function startsWith(s:String):Bool {
        return text.substr(i, s.length) == s;
    }

    inline function isSpace(c:Int):Bool {
        return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
    }

    inline function isTagNameChar(c:Int):Bool {
        return HaxeStringLexer.isIdentPart(c) || c == '.'.code;
    }

    inline function isAttrNameChar(c:Int):Bool {
        return HaxeStringLexer.isIdentPart(c) || c == '-'.code;
    }

    function skipSpaces():Void {
        while (i < contentEnd && isSpace(text.charCodeAt(i))) i++;
    }

    inline function isDigit(c:Int):Bool {
        return c >= '0'.code && c <= '9'.code;
    }

    /** The identifier starting at `i`, without consuming it. */
    function peekIdent():String {
        var end = i;
        while (end < contentEnd && HaxeStringLexer.isIdentPart(text.charCodeAt(end))) end++;
        return text.substring(i, end);
    }

    /** Integers, hex, decimals and exponents, as MarkupToVDom's RE_ANY_NUMBER. */
    function skipNumber():Void {
        while (i < contentEnd) {
            final c = text.charCodeAt(i);
            final previous = text.charCodeAt(i - 1);
            final isExponentSign = (c == '+'.code || c == '-'.code) && (previous == 'e'.code || previous == 'E'.code);
            if (HaxeStringLexer.isIdentPart(c) || c == '.'.code || isExponentSign) i++;
            else break;
        }
    }

    function skipAttrString():Void {

        i++; // opening quote
        while (i < contentEnd) {
            final interp = interpAt(i);
            if (interp != null) { i = interp.end; continue; }
            final c = text.charCodeAt(i);
            if (c == '\\'.code) { i += 2; continue; }
            if (c == '"'.code) { i++; return; }
            i++;
        }
        issue(contentEnd, "Unterminated attribute value");

    }

    function skipLineComment():Void {

        final start = i;
        i += 2;
        while (i < contentEnd && text.charCodeAt(i) != '\n'.code) i++;
        region.comments.push({start: start, end: i, kind: Line});

    }

    function skipBlockComment():Void {

        final start = i;
        i += 2;
        while (i + 1 < contentEnd) {
            if (text.charCodeAt(i) == '*'.code && text.charCodeAt(i + 1) == '/'.code) {
                i += 2;
                region.comments.push({start: start, end: i, kind: Block});
                return;
            }
            i++;
        }
        i = contentEnd;
        region.comments.push({start: start, end: i, kind: Block});

    }

    function skipMarkupComment():Void {

        final start = i;
        i += 4; // `<!--`
        while (i + 2 < contentEnd) {
            if (text.charCodeAt(i) == '-'.code && text.charCodeAt(i + 1) == '-'.code && text.charCodeAt(i + 2) == '>'.code) {
                i += 3;
                region.comments.push({start: start, end: i, kind: Markup});
                return;
            }
            i++;
        }
        i = contentEnd;
        region.comments.push({start: start, end: i, kind: Markup});

    }

    inline function issue(offset:Int, message:String):Void {
        region.issues.push({offset: offset, message: message});
    }

}
