package wisdom.lsp.features;

import wisdom.lsp.Protocol;
import wisdom.lsp.TextDocument;
import wisdom.lsp.features.WebData;
import wisdom.lsp.features.WisdomDocs;
import wisdom.lsp.markup.MarkupTypes;

using StringTools;

/**
 * Everything that can be answered without the Haxe compiler.
 *
 * This is deliberately the first thing every handler reaches for: it costs a
 * few map lookups, it is correct whether or not a Haxe display server is
 * running, and on a project with no usable hxml configuration it is all the
 * user gets -- so it has to stand on its own.
 *
 * The element and attribute tables are the ones Wisdom itself validates
 * against at runtime (`wisdom.HtmlBackend.isAttribute`), reached through
 * `@:privateAccess` because they are private statics. Reusing them rather than
 * copying means the editor can never disagree with the renderer about what is
 * a valid attribute.
 */
class LocalCompletions {

    /**
     * Accepted on any tag, element or component: MarkupToVDom.getTopLevelKey's
     * keys (`ref`, `unmanaged`, `style`, `class`/`className`/`classes`, `on`,
     * `props`) plus the control attributes. `attrs` is deliberately absent: it
     * is not a Wisdom key and would be forwarded as an ordinary prop.
     */
    static final UNIVERSAL_ATTRS = WisdomDocs.UNIVERSAL_ATTR_NAMES;

    /** Attribute families that are open-ended, so only worth offering as a stub. */
    static final ATTR_FAMILIES = ["data-", "aria-"];

    /**
     * `HtmlAttributes` accepts any `on*` attribute without listing any, so the
     * common DOM events have to be named here to be offerable at all. Lowercase
     * because that is what MarkupToVDom moves into `on:{}` for elements.
     */
    static final EVENT_ATTRS = [
        "onclick", "ondblclick", "onmousedown", "onmouseup", "onmouseenter", "onmouseleave",
        "onmousemove", "onmouseover", "onmouseout", "onwheel", "oncontextmenu",
        "onkeydown", "onkeyup", "onkeypress",
        "oninput", "onchange", "onsubmit", "onreset", "onfocus", "onblur", "onselect",
        "ondragstart", "ondragover", "ondragenter", "ondragleave", "ondrop", "ondragend",
        "onscroll", "onload", "onerror", "ontouchstart", "ontouchmove", "ontouchend",
        "onpointerdown", "onpointerup", "onpointermove", "onanimationend", "ontransitionend"
    ];

    static final CONTROL_SNIPPETS:Map<String, String> = [
        // `\$` escapes the snippet syntax, leaving a literal `$` for Wisdom.
        "if"      => "if \\${${1:condition}}>$0</if>",
        "elseif"  => "elseif \\${${1:condition}}>$0",
        "else"    => "else>$0",
        "switch"  => "switch \\${${1:value}}>\n\t<case ${2:pattern}>$0</case>\n</switch>",
        "case"    => "case ${1:pattern}>$0</case>",
        "default" => "default>$0</default>",
        "foreach" => "foreach \\${${1:items}} \\${(${2:i}, ${3:item}) -> '<>$0'} />",
        "key"     => "key \\${${1:id}} />",
        "portal"  => "portal into=\\${${1:host}}>$0</portal>"
    ];

    /**
     * Tag names, for both `<name` and `</name`.
     *
     * Components are not here: resolving them needs the compiler, and they are
     * merged in by the completion feature when one is available.
     */
    public static function tagNames(
        doc:TextDocument, region:MarkupRegion, tag:MarkupTag,
        prefixStart:Int, cursor:Int, isClosing:Bool,
        stack:Array<MarkupTag>, html:Bool
    ):Array<CompletionItem> {

        final range = doc.rangeAt(prefixStart, cursor);
        final prefix = doc.content.substring(prefixStart, cursor);
        final items:Array<CompletionItem> = [];

        if (isClosing) {
            // The tag actually open here is nearly always the one wanted, so it
            // comes first and nothing else competes with it for the top slot.
            var order = 0;
            var n = stack.length - 1;
            while (n >= 0) {
                final open = stack[n];
                if (open.name != "") {
                    items.push(item(open.name, Property, range, open.name + ">",
                        order == 0 ? "closes the tag open here" : "closes an enclosing tag",
                        null, sort(order)));
                }
                order++;
                n--;
            }
            return items;
        }

        // A dotted prefix is a type path: only components can match, and those
        // come from the compiler.
        if (prefix.indexOf(".") != -1) return items;

        // Snippets rewrite the whole tag, so they are only safe while it is
        // still just `<name` with nothing after it.
        final allowSnippets = tag.tagEnd == -1 && tag.attrs.length == 0 && tag.positional.length == 0;

        for (name in controlTagsAt(stack)) {
            final snippet = allowSnippets ? CONTROL_SNIPPETS.get(name) : null;
            items.push(item(name, Keyword, range, snippet != null ? snippet : name,
                WisdomDocs.summary(name), name, sort(0)));
        }

        // Directly inside a `<switch>`, a branch is the only legal child.
        if (onlyBranches(stack)) return items;

        // An uppercase prefix cannot be an element.
        if (prefix.length > 0 && prefix.charCodeAt(0) >= 'A'.code && prefix.charCodeAt(0) <= 'Z'.code) {
            return items;
        }

        // Elements only exist on the HTML backend. On any other backend, or when
        // the backend is unknown, offering `<div>` would be wrong rather than
        // merely unhelpful.
        if (!html) return items;

        // Documentation is filled on `completionItem/resolve`: a `<` completion
        // lists a couple of hundred elements, and shipping every description up
        // front would turn a few kilobytes into tens.
        for (name in htmlTags()) {
            items.push(item(name, Property, range, name, null, null, sort(1), null, webTag(name)));
        }
        for (name in svgTags()) {
            items.push(item(name, Property, range, name, null, null, sort(2), "SVG element", webTag(name)));
        }

        return items;

    }

    /**
     * Attribute names.
     *
     * For an element this is the whole answer. For a component only the
     * universal attributes are known here; its `@props` need the compiler.
     */
    public static function attrNames(
        doc:TextDocument, tag:MarkupTag,
        prefixStart:Int, cursor:Int, used:Array<String>, html:Bool
    ):Array<CompletionItem> {

        final range = doc.rangeAt(prefixStart, cursor);
        final items:Array<CompletionItem> = [];

        inline function add(name:String, kind:CompletionItemKind, doc_:Null<String>, order:Int, ?detail:String, ?data:Dynamic) {
            if (used.indexOf(name) != -1) return;
            items.push(item(name, kind, range, name + valueTemplate(tag, name), doc_, name, sort(order), detail, data));
        }

        for (name in UNIVERSAL_ATTRS) add(name, Field, WisdomDocs.attributeSummary(name), 1);

        switch tag.kind {
            case Html if (html):
                for (name in htmlAttrsFor(tag.name)) add(name, Field, null, 0, webDetail(tag.name, name), webAttr(tag.name, name));
                for (name in EVENT_ATTRS) add(name, Event, null, 0, "DOM event handler", webAttr(tag.name, name));
                for (name in svgAttrsFor(tag.name)) add(name, Field, null, 0, webDetail(tag.name, name), webAttr(tag.name, name));
                for (family in ATTR_FAMILIES) {
                    items.push(item(family, Field, range, family + "$1=\"$2\"",
                        "Any " + family + "* attribute is accepted.", family, sort(2)));
                }
            case _:
        }

        return items;

    }

    /**
     * Values of an enumerated attribute, inside its quotes: `type="|"`.
     *
     * Null whenever there is nothing safe to offer -- no value set, a boolean
     * attribute (whose values are not strings, see `valueTemplate`), or an
     * interpolation already in the value that a replacement would clobber.
     */
    public static function attrValues(doc:TextDocument, tag:MarkupTag, attr:MarkupAttr, cursor:Int):Null<CompletionList> {

        final values = WebData.valuesOf(tag.name, attr.name);
        if (values == null || values.length == 0) return null;
        if (WebData.isBoolean(tag.name, attr.name)) return null;
        if (attr.valueStart == -1) return null;

        final text = doc.content;
        final start = attr.valueStart + 1;
        var end = attr.valueEnd;
        // `valueEnd` is past the closing quote when there is one.
        if (end > start && text.charCodeAt(end - 1) == '"'.code) end--;
        if (end < start) end = start;
        if (text.substring(start, end).indexOf("$") != -1) return null;

        // Replace the whole value, as VSCode's HTML support does: completing
        // `type="bu|tton"` yields `button`, not `buttontton`.
        var range = doc.rangeAt(start, end);
        if (range.start.line != range.end.line) range = doc.rangeAt(start, cursor);

        final items:Array<CompletionItem> = [];
        for (index in 0...values.length) {
            final value = values[index];
            items.push({
                label: value,
                kind: Value,
                filterText: value,
                // Source order: `text` before `hidden` is not alphabetical.
                sortText: StringTools.lpad(Std.string(index), "0", 3),
                insertTextFormat: PlainText,
                textEdit: ({range: range, newText: value} : TextEdit)
            });
        }

        return {isIncomplete: false, items: items};

    }

    /// Web data decoration

    static inline function webTag(name:String):Dynamic {
        return {web: {kind: "tag", tag: name}};
    }

    static inline function webAttr(tag:String, name:String):Dynamic {
        return {web: {kind: "attr", tag: tag, name: name}};
    }

    /** What shows next to the attribute name: its value set, or that it is boolean. */
    static function webDetail(tag:String, name:String):Null<String> {

        final info = WebData.attribute(tag, name);
        // Accepted by the renderer but unknown to the documentation: obsolete.
        if (info == null) return "legacy";
        if (info.isBoolean) return "boolean attribute";
        if (info.values != null && info.values.length > 0) {
            final shown = info.values.length > 6 ? info.values.slice(0, 6) : info.values;
            return shown.join(" | ") + (info.values.length > 6 ? " | …" : "");
        }
        return null;

    }

    /// Tag and attribute tables

    static function controlTagsAt(stack:Array<MarkupTag>):Array<String> {

        final names = ["if", "switch", "foreach", "key", "portal"];

        // `<elseif>`/`<else>` only continue an `<if>`, and `<case>`/`<default>`
        // only live in a `<switch>`. Offering them anywhere else is noise that
        // MarkupToVDom would reject outright.
        final top = stack.length > 0 ? stack[stack.length - 1] : null;
        if (top != null) {
            switch top.kind {
                case Control(CIf) | Control(CElseIf):
                    names.push("elseif");
                    names.push("else");
                case Control(CSwitch) | Control(CCase) | Control(CDefault):
                    names.push("case");
                    names.push("default");
                case _:
            }
        }
        if (onlyBranches(stack)) return ["case", "default"];

        return names;

    }

    /** True directly inside a `<switch>`, where only branches may appear. */
    static function onlyBranches(stack:Array<MarkupTag>):Bool {

        if (stack.length == 0) return false;
        return switch stack[stack.length - 1].kind {
            case Control(CSwitch): true;
            case _: false;
        }

    }

    static function htmlTags():Array<String> {
        return @:privateAccess [for (name in wisdom.HtmlAttributes.elements.keys()) name];
    }

    static function svgTags():Array<String> {
        // Names shared with HTML are already offered; only the genuinely SVG ones.
        return @:privateAccess [
            for (name in wisdom.SvgAttributes.elements.keys())
            if (!wisdom.HtmlAttributes.elements.exists(name)) name
        ];
    }

    static function htmlAttrsFor(tag:String):Array<String> {

        final lower = tag.toLowerCase();
        return @:privateAccess {
            final found = [for (name in wisdom.HtmlAttributes.globalAttrs.keys()) name];
            found.push("role");
            for (name => elements in wisdom.HtmlAttributes.attrElements) {
                if (elements.indexOf(lower) != -1) found.push(name);
            }
            for (name => elements in wisdom.HtmlAttributes.legacyAttrs) {
                if (elements.indexOf(lower) != -1) found.push(name);
            }
            found;
        }

    }

    static function svgAttrsFor(tag:String):Array<String> {

        return @:privateAccess {
            if (!wisdom.SvgAttributes.isValidTag(tag)) [];
            else [
                for (name in wisdom.SvgAttributes.attrs.keys())
                if (!wisdom.HtmlAttributes.globalAttrs.exists(name)) name
            ];
        }

    }

    /// Item construction

    /**
     * How an attribute's value is spelled.
     *
     * An event handler or a condition is Haxe, so it wants `${}`; a class or a
     * plain HTML attribute is usually a literal string.
     */
    static function valueTemplate(tag:MarkupTag, name:String):String {

        // Wisdom's own attributes first: their spelling never depends on the element.
        switch name {
            case "if" | "unless": return "=\\${${1:condition}}";
            case "key": return "=\\${${1:id}}";
            // The one attribute MarkupToVDom accepts without a value.
            case "unmanaged": return "";
            case "ref": return "=\\${${1:element} -> $2}";
            case "style" | "on" | "props" | "classes": return "=\\${$1}";
            case _:
        }

        switch tag.kind {
            case Html:
                // A boolean attribute is set by `true` and removed by `false`,
                // both as Haxe values; a quoted "false" would set it.
                if (WebData.isBoolean(tag.name, name)) return "=${1|true,false|}";
                final values = WebData.valuesOf(tag.name, name);
                if (values != null && values.length > 0 && values.length <= 12) {
                    return "=\"${1|" + values.join(",") + "|}\"";
                }
            case _:
        }

        if (name.startsWith("on")) return "=\\${${1:handler}}";
        return "=\"$1\"";

    }

    static function item(
        label:String, kind:CompletionItemKind, range:Range, newText:String,
        ?documentation:String, ?filterText:String, ?sortText:String,
        ?detail:String, ?data:Dynamic
    ):CompletionItem {

        final isSnippet = newText.indexOf("$") != -1;

        return {
            label: label,
            kind: kind,
            detail: detail,
            documentation: documentation,
            filterText: filterText != null ? filterText : label,
            sortText: sortText,
            insertTextFormat: isSnippet ? Snippet : PlainText,
            textEdit: ({
                range: range,
                newText: newText
            } : TextEdit),
            data: data
        };

    }

    /** Groups appear in the order given, alphabetical within a group. */
    static inline function sort(group:Int):String {
        return group + "_";
    }

}
