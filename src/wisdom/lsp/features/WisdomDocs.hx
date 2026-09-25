package wisdom.lsp.features;

import wisdom.lsp.markup.MarkupTypes;

typedef WisdomDoc = {
    /** How it is written, shown in a code fence. */
    var syntax:String;
    /** One line, for completion items. */
    var summary:String;
    /** The full explanation, markdown. */
    var description:String;
    /** Anchor in the Wisdom README. */
    var anchor:String;
}

/**
 * What Wisdom's own tags and attributes mean.
 *
 * The single source for both the one-line summaries completion shows and the
 * hover text. Everything here is derived from `wisdom.MarkupToVDom` -- what the
 * compiler actually accepts -- and from the library README, so that the editor
 * never describes a behaviour the runtime does not have.
 */
class WisdomDocs {

    static inline var README = "https://github.com/jeremyfa/wisdom#";

    /// Tags

    static final TAGS:Map<String, WisdomDoc> = [
        "if" => {
            syntax: "<if ${condition}>...<elseif ${other}>...<else>...</if>",
            summary: "Render the body only when the condition holds.",
            description: "Takes one positional condition, `$flag` or `${expr}`, and compiles to a Haxe `if`. "
                + "Further branches are written *inside* it as `<elseif ${cond}>` and `<else>`, which have no "
                + "closing tag of their own: a single `</if>` closes the whole chain.",
            anchor: "if-statements"
        },
        "elseif" => {
            syntax: "<if ${a}>...<elseif ${b}>...</if>",
            summary: "Another branch of the enclosing `<if>`.",
            description: "Continues the enclosing `<if>` with a new condition. It must follow the content of an "
                + "`<if>` or `<elseif>` directly and has no closing tag; the chain ends at `</if>`.",
            anchor: "if-statements"
        },
        "else" => {
            syntax: "<if ${cond}>...<else>...</if>",
            summary: "Fallback branch of the enclosing `<if>`.",
            description: "The last branch of the enclosing `<if>`, rendered when no condition held. "
                + "No closing tag of its own; the chain ends at `</if>`.",
            anchor: "if-statements"
        },
        "switch" => {
            syntax: "<switch ${value}>\n    <case \"a\">...</case>\n    <default>...</default>\n</switch>",
            summary: "Match a value against `<case>` branches.",
            description: "Compiles to a Haxe `switch` on the positional value. Its direct children may only be "
                + "`<case>` and `<default>`; anything else is an error.",
            anchor: "switch-statements"
        },
        "case" => {
            syntax: "<case \"literal\">...</case>",
            summary: "One branch of the enclosing `<switch>`.",
            description: "The pattern is a string, a number, `true`, `false`, `null`, `_`, or `${pattern}` for any "
                + "Haxe pattern -- an enum constructor with captures, for instance. An `if=${guard}` attribute "
                + "becomes a `case ... if (guard)` guard.",
            anchor: "switch-statements"
        },
        "default" => {
            syntax: "<default>...</default>",
            summary: "Fallback branch of the enclosing `<switch>`.",
            description: "Rendered when no `<case>` matched. Equivalent to `<case _>`.",
            anchor: "switch-statements"
        },
        "foreach" => {
            syntax: "<foreach ${items} ${(index, item) -> '<>\n    ...\n'} />",
            summary: "Repeat markup for each item of a collection.",
            description: "Self-closing, with exactly two positional values: the collection to iterate (an array, "
                + "an iterator, a range such as `${0...n}`) and a function receiving `(index, item)` that returns "
                + "the markup for one item -- usually a nested `'<>...'` literal. Compiles to an array comprehension.",
            anchor: "foreach-loops"
        },
        "key" => {
            syntax: "<key ${id} />",
            summary: "Give the current `<foreach>` item a stable identity.",
            description: "Self-closing, with one positional value. Inside a `<foreach>` it identifies the item "
                + "being rendered, so its elements and component state follow it when the list is reordered. "
                + "The `key=${...}` attribute on the item's root element is the usual shorthand.",
            anchor: "key-attribute"
        },
        "portal" => {
            syntax: "<portal into=${host}>...</portal>",
            summary: "Render children inside an element owned by someone else.",
            description: "The children are rendered into `host` -- a container created by another library, "
                + "`document.body` for a modal -- while a comment node keeps their place here. They remain "
                + "ordinary Wisdom children: diffed in place, state preserved, destroyed with the portal. "
                + "`into` is required; only `into`, `key`, `if` and `unless` are accepted.",
            anchor: "portal-intohost"
        }
    ];

    /// Attributes

    static final ATTRS:Map<String, WisdomDoc> = [
        "if" => {
            syntax: "<div if=${condition}>",
            summary: "Render this node only when the condition holds.",
            description: "A conditional attribute, accepted on elements and components alike. May be repeated; "
                + "every condition must hold. On a `<case>` it becomes the branch's guard.",
            anchor: "conditional-attributes"
        },
        "unless" => {
            syntax: "<div unless=${condition}>",
            summary: "Render this node unless the condition holds.",
            description: "The negation of `if`. May be repeated and combined with `if`; the node renders only when "
                + "every `if` holds and no `unless` does.",
            anchor: "conditional-attributes"
        },
        "key" => {
            syntax: "<li key=${item.id}>",
            summary: "Stable identity of this node across renders.",
            description: "Sets the node's identity, so that elements and component state follow it when siblings "
                + "are inserted, removed or reordered. Consumed by the compiler; never forwarded as a prop.",
            anchor: "key-attribute"
        },
        "class" => {
            syntax: "<div class=\"a b\"> or <div class=${[\"a\", \"b\"]}>",
            summary: "CSS classes, as a string or an array.",
            description: "A space-separated string or an `Array<String>`. `class`, `className` and `classes` are "
                + "three spellings of the same attribute.",
            anchor: "attributes"
        },
        "className" => {
            syntax: "<div className=\"a b\">",
            summary: "Alias of `class`.",
            description: "Same as `class`: a space-separated string or an `Array<String>`.",
            anchor: "attributes"
        },
        "classes" => {
            syntax: "<div classes=${[\"a\", \"b\"]}>",
            summary: "Alias of `class`.",
            description: "Same as `class`: a space-separated string or an `Array<String>`.",
            anchor: "attributes"
        },
        "style" => {
            syntax: "<div style=${{color: \"red\"}}> or <div style=\"color: red\">",
            summary: "Inline style, as an object or a CSS string.",
            description: "An object of CSS properties, or a CSS declaration string. Changed properties are patched "
                + "individually on re-render.",
            anchor: "attributes"
        },
        "on" => {
            syntax: "<button on=${{click: onClick, keydown: onKey}}>",
            summary: "All event listeners at once, as an object.",
            description: "Cannot be combined with individual `on*` attributes on the same node. Individual "
                + "listeners also work: on an element `onclick=${...}` (any casing, lowercased after `on`) is an "
                + "event; on a component `onClose=${...}` is an ordinary prop and keeps its casing.",
            anchor: "attributes"
        },
        "props" => {
            syntax: "<Button props=${{label: \"Save\", disabled: busy}}>",
            summary: "All props at once, as an object.",
            description: "Passes every prop in one object. Cannot be combined with other attributes on the same node.",
            anchor: "usage-in-markup"
        },
        "ref" => {
            syntax: "<div ref=${element -> map.attach(element)}>",
            summary: "Be told when the element is attached and destroyed.",
            description: "The callback receives the element once it is attached, at the end of the patch that "
                + "created it, and `null` when the element is destroyed. Changing the callback between renders "
                + "does not call anything.",
            anchor: "ref"
        },
        "unmanaged" => {
            syntax: "<div class=\"editor\" unmanaged />",
            summary: "Let another library own this element's children.",
            description: "Wisdom creates and updates the element -- classes, style, attributes, listeners -- but "
                + "never creates, diffs or removes its DOM children: a third-party library fills it. The only "
                + "attribute that may be written without a value.",
            anchor: "unmanaged"
        },
        "into" => {
            syntax: "<portal into=${container.element}>",
            summary: "The element a `<portal>` renders into.",
            description: "Required on `<portal>`. When it changes for the same portal, the children are moved to "
                + "the new host with their elements and state intact.",
            anchor: "portal-intohost"
        }
    ];

    /// Queries

    public static function tag(name:String):Null<WisdomDoc> {
        return TAGS.get(name);
    }

    public static function attribute(name:String):Null<WisdomDoc> {
        return ATTRS.get(name);
    }

    /** Every tag documented here, in a sensible completion order. */
    public static final TAG_NAMES:Array<String> = [
        "if", "elseif", "else", "switch", "case", "default", "foreach", "key", "portal"
    ];

    /** The attributes accepted on any tag, element or component. */
    public static final UNIVERSAL_ATTR_NAMES:Array<String> = [
        "class", "className", "classes", "style", "on", "props", "key", "if", "unless", "ref", "unmanaged"
    ];

    /** The one-line summary of a tag or attribute, for completion items. */
    public static function summary(name:String):Null<String> {

        final asTag = TAGS.get(name);
        if (asTag != null) return asTag.summary;
        final asAttr = ATTRS.get(name);
        return asAttr != null ? asAttr.summary : null;

    }

    public static function attributeSummary(name:String):Null<String> {

        final doc = ATTRS.get(name);
        return doc != null ? doc.summary : null;

    }

    /// Hover text
    //
    // Signature fence, then prose, then the README link -- the same shape as the
    // `class Switch` hover on components, so the two read as one voice.

    public static function tagHover(name:String):Null<String> {

        final doc = TAGS.get(name);
        return doc != null ? render(doc) : null;

    }

    /**
     * `into` only means something on a `<portal>`; everywhere else it is an
     * ordinary attribute and the caller should look elsewhere.
     */
    public static function attributeHover(name:String, tagName:String):Null<String> {

        if (name == "into" && tagName != "portal") return null;
        final doc = ATTRS.get(name);
        return doc != null ? render(doc) : null;

    }

    static function render(doc:WisdomDoc):String {

        return "```html\n" + doc.syntax + "\n```\n\n"
            + doc.description + "\n\n"
            + "[Wisdom README](" + README + doc.anchor + ")";

    }

}
