package wisdom.lsp.markup;

/**
 * Shapes produced by the two scanning passes.
 *
 * Every offset in here is a raw offset into the **document text**, never into
 * the decoded content of a string literal. That is a deliberate constraint: it
 * means nothing ever has to reconcile `\'` escapes between two coordinate
 * systems, and every span can be handed to the editor as-is.
 */

/** Which Wisdom control-flow tag this is. */
enum ControlKind {
    CIf;
    CElseIf;
    CElse;
    CSwitch;
    CCase;
    CDefault;
    CForeach;
    CKey;
}

enum MarkupTagKind {
    /** Lowercase name: an HTML or SVG element. */
    Html;
    /** Matches `RE_TAG_COMPONENT`: resolves to a Haxe type or `@x` function. */
    Component;
    Control(kind:ControlKind);
    /** Recognised as a tag, but the name fits nothing. */
    Unknown;
}

enum AttrValueKind {
    /** `<div foo>` -- rejected by MarkupToVDom, but we still record it. */
    VNone;
    /** `attr="..."`, which may itself contain interpolations. */
    VDoubleQuoted;
    /** `attr=$ident` */
    VDollarIdent;
    /** `attr=${expr}` */
    VDollarBraced;
    /** `attr=42`, `attr=true`, `attr=null` */
    VLiteral;
}

enum CommentKind {
    Line;
    Block;
    /** `<!-- ... -->` */
    Markup;
}

/**
 * A `$ident` or `${expr}` interpolation.
 *
 * `exprStart`/`exprEnd` bound the Haxe expression itself, which is what
 * `contextAt` tests the cursor against: inside that span the compiler already
 * sees ordinary interpolated code and vshaxe answers correctly, so we must not.
 */
typedef InterpSpan = {
    /** Offset of the `$`. */
    var start:Int;
    var exprStart:Int;
    var exprEnd:Int;
    /** Offset just past the interpolation (past `}` when braced). */
    var end:Int;
    var braced:Bool;
    /** False when a braced interpolation was never closed. */
    var balanced:Bool;
}

typedef MarkupAttr = {
    var name:String;
    var nameStart:Int;
    var nameEnd:Int;
    var valueKind:AttrValueKind;
    /** -1 when there is no value. */
    var valueStart:Int;
    var valueEnd:Int;
}

typedef MarkupTag = {
    var kind:MarkupTagKind;
    var name:String;
    var nameStart:Int;
    var nameEnd:Int;
    /** Offset of `<`. */
    var tagStart:Int;
    /** Offset just past `>`, or -1 while the tag is still unterminated. */
    var tagEnd:Int;
    /**
     * Offset of the `<` of the matching closing tag, or -1 when never closed.
     * Together with `tagEnd` this bounds the tag's content, which is what
     * `tagStackAt` walks.
     */
    var closeStart:Int;
    var selfClosing:Bool;
    /** True for `</name>`. */
    var closing:Bool;
    var attrs:Array<MarkupAttr>;
    /**
     * Positional `$`/`${}` values: the condition of `<if>`, the two values of
     * `<foreach>`, the subject of `<switch>`, the key of `<key>`.
     */
    var positional:Array<InterpSpan>;
    var children:Array<MarkupTag>;
    var parent:Null<MarkupTag>;
    var region:MarkupRegion;
}

typedef MarkupComment = {
    var start:Int;
    /** Offset just past the comment. */
    var end:Int;
    var kind:CommentKind;
}

typedef MarkupIssue = {
    var offset:Int;
    var message:String;
}

/**
 * One `'<>...'` string literal.
 *
 * Nested regions are those written inside an interpolation of this one, which
 * is how `<foreach ${(i, item) -> '<>...'}>` is spelled. Note this nesting is
 * **not** backslash-escaped in practice: inside `${...}` Haxe reads code again,
 * where a plain `'...'` literal is legal.
 */
typedef MarkupRegion = {
    /** Offset of the opening `'`. */
    var quoteStart:Int;
    /** Offset just past `<>`, where the markup itself begins. */
    var contentStart:Int;
    /** Offset of the closing `'`, or the end of the document if unterminated. */
    var contentEnd:Int;
    var terminated:Bool;
    /** 0 for markup written directly in Haxe code. */
    var depth:Int;
    var parent:Null<MarkupRegion>;
    var children:Array<MarkupRegion>;
    var interps:Array<InterpSpan>;
    /** Top-level tags; nested ones hang off `MarkupTag.children`. */
    var roots:Array<MarkupTag>;
    /** Every tag of this region, opening and closing, in document order. */
    var tags:Array<MarkupTag>;
    var comments:Array<MarkupComment>;
    var issues:Array<MarkupIssue>;
    /** False until pass B has run over this region. */
    var scanned:Bool;
}

typedef ScanResult = {
    var text:String;
    /** Every region at any depth, ordered by `quoteStart`. */
    var regions:Array<MarkupRegion>;
    var topRegions:Array<MarkupRegion>;
}

/**
 * Where the cursor is, and therefore who should answer.
 *
 * `OutsideMarkup`, `InHaxeExpr` and `InComment` all mean "not ours": the
 * handler returns null and vshaxe's answer stands alone.
 */
enum CursorContext {
    OutsideMarkup;

    InText(region:MarkupRegion, enclosing:Null<MarkupTag>);

    /**
     * On a tag name, open or closing. `prefixSoFar` is the text between the
     * start of the name and the cursor -- what the user has typed so far.
     */
    InOpenTagName(region:MarkupRegion, tag:MarkupTag, prefixSoFar:String, prefixStart:Int, isClosing:Bool);

    /**
     * On (or where one would start) an attribute name. `alreadyUsedAttrs`
     * excludes the attribute being edited, and keeps `if`/`unless`, which may
     * legitimately repeat.
     */
    InAttrName(region:MarkupRegion, tag:MarkupTag, prefixSoFar:String, prefixStart:Int, alreadyUsedAttrs:Array<String>);

    /** Inside `attr="..."`, but outside any `${}` within it. */
    InAttrStringValue(region:MarkupRegion, tag:MarkupTag, attr:MarkupAttr);

    /** Inside `$ident` / `${expr}`: vshaxe territory. */
    InHaxeExpr(region:MarkupRegion, interp:InterpSpan);

    InComment(region:MarkupRegion, kind:CommentKind);
}
