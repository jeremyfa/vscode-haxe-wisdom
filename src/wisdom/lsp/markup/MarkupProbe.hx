package wisdom.lsp.markup;

import wisdom.lsp.markup.MarkupScanner;
import wisdom.lsp.markup.MarkupTypes;

/**
 * Builds the expression handed to the Haxe compiler in place of a markup
 * literal, and says where the cursor lands inside it.
 *
 * The wrapper is always the same:
 *
 *     ({ var _w0 = <expr>; null; } : String)
 *
 * `: String` because that is the type the literal had (`wisdom.VNode` has a
 * `@:from String`), so the probe is valid wherever the literal was -- a
 * `return`, a `var`, an argument. `var _w0 =` forces the parser to read `{` as
 * a block rather than an anonymous object. The trailing `null` leaves the
 * block's value free.
 *
 * Replacing the whole literal, rather than inserting into it, also means none
 * of the user's own interpolations are typed. Haxe types an interpolated string
 * left to right, so one broken `${...}` earlier in the markup would otherwise
 * abort typing before ever reaching the probe.
 *
 * `_w` is the sentinel appended to a partial name. It makes every prefix shape
 * syntactically valid -- `_w`, `Butt_w`, `kit.ui._w`, `kit.ui.Bu_w` -- so we
 * never depend on the parser tolerating a trailing dot. It costs nothing,
 * because Haxe does not filter completion results by prefix anyway.
 */
class MarkupProbe {

    public static inline var HEAD = "({ var _w0 = ";
    public static inline var TAIL = "; null; } : String)";
    public static inline var SENTINEL = "_w";

    public var buffer(default, null):VirtualBuffer;

    /** Codepoint offset to send to Haxe, already converted. */
    public var offset(default, null):Int;

    function new(buffer:VirtualBuffer, offset:Int) {
        this.buffer = buffer;
        this.offset = offset;
    }

    /**
     * Build a probe replacing the region containing the cursor.
     *
     * Always the **outermost** region: a nested one lives inside an
     * interpolation of its parent, so replacing only the inner literal would
     * leave the parent's markup as a half-written string.
     */
    public static function build(text:String, region:MarkupRegion, expression:String, cursorInExpression:Int):MarkupProbe {

        final outer = MarkupScanner.outermost(region);

        final at = outer.quoteStart;
        // Past the closing quote when there is one; an unterminated literal
        // runs to wherever the lexer stopped.
        final end = outer.terminated ? outer.contentEnd + 1 : outer.contentEnd;

        final buffer = new VirtualBuffer(text, at, end - at, HEAD + expression + TAIL);
        final cursor = at + HEAD.length + cursorInExpression;

        return new MarkupProbe(buffer, buffer.codepointOffset(cursor));

    }

    /// The probes, one per feature

    /**
     * (a) Completing a tag name: `<kit.ui.Bu|` -> `kit.ui.Bu_w`.
     *
     * Toplevel completion when the prefix has no dot, field completion on the
     * package or module when it does. Haxe returns everything either way; the
     * filtering is ours.
     */
    public static function forTagName(text:String, region:MarkupRegion, prefix:String):MarkupProbe {

        final expression = prefix + SENTINEL;
        return build(text, region, expression, expression.length);

    }

    /**
     * (b) and (c) Hover and go to definition on a tag name.
     *
     * The name is written exactly as in the source, so the file's own
     * `import`, `using` and `import.hx` resolve it -- which is what makes
     * `import kit.ui.*` work with no index of our own.
     */
    public static function forTagIdentifier(text:String, region:MarkupRegion, tagName:String, cursorInName:Int):MarkupProbe {

        // Keep the cursor strictly inside the identifier: on its edges Haxe
        // answers about the surrounding expression instead.
        var at = cursorInName;
        if (at < 1) at = 1;
        if (at > tagName.length) at = tagName.length;
        return build(text, region, tagName, at);

    }

    /**
     * (e) Hover on one attribute of a class component: `<Button label=...>`
     * -> `@:privateAccess (null : Button).label`, cursor inside `label`.
     *
     * The same access expression as (d1), pointed at a single field, so the
     * compiler answers with that field's type and documentation.
     */
    public static function forComponentProp(text:String, region:MarkupRegion, tagName:String, propName:String, cursorInName:Int):MarkupProbe {

        final expression = '@:privateAccess (null : ${tagName}).${propName}';
        var at = cursorInName;
        if (at < 1) at = 1;
        if (at > propName.length) at = propName.length;
        return build(text, region, expression, expression.length - propName.length + at);

    }

    /**
     * (d1) Attributes of a class component: the `@props` fields.
     *
     * `@:privateAccess` is required -- `@props var label:String` is private by
     * default -- and `(null : T)` is an ordinary type check, valid for any
     * class including the abstract `wisdom.Component` subclasses.
     */
    public static function forComponentProps(text:String, region:MarkupRegion, tagName:String):MarkupProbe {

        final expression = '@:privateAccess (null : ${tagName}).${SENTINEL}';
        return build(text, region, expression, expression.length);

    }

}
