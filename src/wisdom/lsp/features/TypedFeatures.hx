package wisdom.lsp.features;

import wisdom.haxe.DisplayProtocol;
import wisdom.lsp.CancellationToken;
import wisdom.lsp.HaxeBackend;
import wisdom.lsp.Protocol;
import wisdom.lsp.TextDocument;
import wisdom.lsp.markup.ComponentSourceScanner;
import wisdom.lsp.markup.MarkupProbe;
import wisdom.lsp.markup.MarkupTypes;

using StringTools;

/**
 * Everything that needs the Haxe compiler: component names, their `@props`,
 * hover and go to definition on a tag.
 *
 * Each of these replaces the markup literal with a small probe expression,
 * asks the compiler about that, and maps the answer back onto spans the
 * scanner already knows. Using our own spans rather than the compiler's
 * `replaceRange` matters: the compiler's positions point into synthetic text.
 */
class TypedFeatures {

    /** How long the first request waits for a cold compiler before giving up. */
    static inline var WARM_UP_GRACE_MS = 1500;

    final backend:HaxeBackend;

    /**
     * Guards `completionItem/resolve`.
     *
     * Haxe's resolve index is only valid against the most recent
     * `display/completion` on that server, so an index from an older batch
     * would quietly return documentation for the wrong symbol.
     */
    var generation:Int = 0;

    public function new(backend:HaxeBackend) {
        this.backend = backend;
    }

    public inline function available():Bool {
        return backend != null && backend.available();
    }

    /// Completion

    /**
     * Component names to merge into the local suggestions.
     *
     * `done(null)` means "no answer yet": the caller then replies
     * `isIncomplete`, and the editor asks again on the next keystroke rather
     * than waiting on a cache build.
     */
    public function componentNames(doc:TextDocument, region:MarkupRegion, tag:MarkupTag,
                                   prefixStart:Int, cursor:Int, token:CancellationToken,
                                   done:(items:Null<Array<CompletionItem>>) -> Void):Void {

        final prefix = doc.content.substring(prefixStart, cursor);
        final probe = MarkupProbe.forTagName(doc.content, region, prefix);
        final range = doc.rangeAt(prefixStart, cursor);

        withCompiler(doc, token, done, () -> {
            final batch = ++generation;
            backend.completion(fsPath(doc.uri), probe.buffer.text, probe.offset, true, token, result -> {
                if (result == null || result.items == null) {
                    done(null);
                    return;
                }
                done(componentItems(result.items, prefix, range, batch));
            });
        });

    }

    /**
     * Filter a toplevel completion down to things that can actually be a tag.
     *
     * Haxe answers with everything in scope -- locals, statics, keywords, every
     * type on the class path, all the packages. There is no supertype
     * information in the response, so "is this a Wisdom component?" cannot be
     * asked directly; what can be asked is "is this a class the file could name
     * here?", which removes the std library and the noise while keeping every
     * real component.
     */
    function componentItems(items:Array<DisplayItem>, prefix:String, range:Range, batch:Int):Array<CompletionItem> {

        final dot = prefix.lastIndexOf(".");
        final packagePrefix = dot == -1 ? null : prefix.substring(0, dot);
        final out:Array<CompletionItem> = [];

        for (item in items) {

            if (item.kind == "Package") {
                // Only useful while writing a dotted path.
                if (packagePrefix == null) continue;
                final path:JsonTypePath = item.args.path;
                final packageName = path.pack.join(".");
                if (!packageName.startsWith(packagePrefix + ".")) continue;
                // Offer one segment at a time, not the whole tail.
                final segment = packageName.substring(packagePrefix.length + 1);
                if (segment.indexOf(".") != -1) continue;
                out.push({
                    label: segment,
                    kind: Module,
                    detail: packageName,
                    filterText: packageName,
                    sortText: "3_" + segment,
                    textEdit: ({range: range, newText: packageName} : TextEdit)
                });
                continue;
            }

            if (item.kind == "ClassField") {
                // An `@x` function component of the enclosing class.
                final field:JsonClassField = item.args.field;
                if (field == null || !hasMeta(field.meta, "x")) continue;
                out.push({
                    label: field.name,
                    kind: Function,
                    detail: "@x component",
                    documentation: field.doc,
                    filterText: field.name,
                    sortText: "0_" + field.name,
                    textEdit: ({range: range, newText: field.name} : TextEdit)
                });
                continue;
            }

            if (item.kind != "Type") continue;

            final type:DisplayModuleType = item.args;
            if (type == null || type.path == null) continue;
            // Only classes: an interface, enum, abstract or typedef is never a tag.
            if (type.kind != 0) continue;
            if (type.isExtern || type.isAbstract || type.isPrivate) continue;

            final packageName = type.path.pack.join(".");

            if (packagePrefix != null) {
                if (packageName != packagePrefix) continue;
                final full = packageName + "." + type.path.typeName;
                out.push({
                    label: type.path.typeName,
                    kind: Class,
                    detail: full,
                    filterText: full,
                    sortText: "1_" + type.path.typeName,
                    textEdit: ({range: range, newText: full} : TextEdit),
                    data: {index: item.index, generation: batch}
                });
                continue;
            }

            // Unqualified: it has to be nameable here as written.
            if (type.path.importStatus != 0) continue;
            // Toplevel types with no package are the standard library.
            if (type.path.pack.length == 0) continue;

            out.push({
                label: type.path.typeName,
                kind: Class,
                detail: packageName,
                filterText: type.path.typeName,
                sortText: "0_" + type.path.typeName,
                textEdit: ({range: range, newText: type.path.typeName} : TextEdit),
                data: {index: item.index, generation: batch}
            });

        }

        return out;

    }

    /**
     * Attributes of a component: its `@props` fields, or an `@x` function's
     * declared arguments.
     */
    public function componentAttributes(doc:TextDocument, region:MarkupRegion, tag:MarkupTag,
                                        prefixStart:Int, cursor:Int, used:Array<String>,
                                        token:CancellationToken,
                                        done:(items:Null<Array<CompletionItem>>) -> Void):Void {

        final range = doc.rangeAt(prefixStart, cursor);
        final file = fsPath(doc.uri);

        withCompiler(doc, token, done, () -> {
            // Which kind of component this is decides the probe, and only the
            // compiler knows: `Type` means a class, a `TFun` field means `@x`.
            final identifier = MarkupProbe.forTagIdentifier(doc.content, region, tag.name, 1);
            backend.hover(file, identifier.buffer.text, identifier.offset, token, hovered -> {

                if (hovered == null || hovered.item == null) {
                    done(null);
                    return;
                }

                if (hovered.item.kind == "ClassField") {
                    functionComponentAttributes(doc, region, tag, hovered, range, used, token, done);
                    return;
                }

                final probe = MarkupProbe.forComponentProps(doc.content, region, tag.name);
                backend.completion(file, probe.buffer.text, probe.offset, true, token, result -> {
                    if (result == null || result.items == null) {
                        done(null);
                        return;
                    }
                    done(propItems(result.items, range, used));
                });
            });
        });

    }

    function propItems(items:Array<DisplayItem>, range:Range, used:Array<String>):Array<CompletionItem> {

        final out:Array<CompletionItem> = [];

        for (item in items) {
            if (item.kind != "ClassField") continue;
            final field:JsonClassField = item.args.field;
            if (field == null || !hasMeta(field.meta, "props")) continue;

            // With tracker, `@props` is also `@observe`d. In display mode the
            // original field survives untouched, but a cache built without
            // `-D completion` reintroduces the mangled twins, and they carry
            // the same metadata -- so filter them by name as well.
            if (~/^unobserved[A-Z]/.match(field.name)) continue;
            if (used.indexOf(field.name) != -1) continue;

            out.push(attributeItem(field.name, printType(field.type, 0), field.doc, range));
        }

        return out;

    }

    /**
     * An `@x` function component: its arguments are its attributes.
     *
     * The typed signature gives names and types but no metadata, so `@state`
     * arguments -- which are component-local state, not props -- are
     * indistinguishable. Those come from the declaration's source instead.
     */
    function functionComponentAttributes(doc:TextDocument, region:MarkupRegion, tag:MarkupTag,
                                         hovered:HoverResult, range:Range, used:Array<String>,
                                         token:CancellationToken,
                                         done:(items:Null<Array<CompletionItem>>) -> Void):Void {

        final signature = hovered.item.type;
        if (signature == null || signature.kind != "TFun") {
            done(null);
            return;
        }

        final args:Array<Dynamic> = signature.args.args;
        if (args == null) {
            done(null);
            return;
        }

        inline function build(fromSource:Null<Array<ComponentArgument>>):Array<CompletionItem> {
            final out:Array<CompletionItem> = [];
            for (arg in args) {
                final name:String = arg.name;
                // Bound to the children of the tag, never written as an attribute.
                if (name == null || name == "children") continue;
                if (used.indexOf(name) != -1) continue;
                if (fromSource != null && isState(fromSource, name)) continue;
                out.push(attributeItem(name, printType(arg.t, 0), null, range));
            }
            return out;
        }

        // Locate the declaration so its `@state` metadata can be read.
        final identifier = MarkupProbe.forTagIdentifier(doc.content, region, tag.name, 1);
        backend.definition(fsPath(doc.uri), identifier.buffer.text, identifier.offset, token, locations -> {

            var fromSource:Array<ComponentArgument> = null;

            if (locations != null && locations.length > 0) {
                final location = locations[0];
                final source = readFile(location.file);
                if (source != null) {
                    // A rough offset is enough: the scanner walks to the next
                    // parenthesis from there.
                    final offset = offsetOfLine(source, location.range.start.line);
                    final scanned = ComponentSourceScanner.readXArgs(source, offset);
                    if (scanned.length > 0) fromSource = scanned;
                }
            }

            done(build(fromSource));
        });

    }

    static function isState(args:Array<ComponentArgument>, name:String):Bool {

        for (arg in args) if (arg.name == name) return arg.isState;
        return false;

    }

    function attributeItem(name:String, type:Null<String>, documentation:Null<String>, range:Range):CompletionItem {

        // How the value is spelled follows its type: a string reads better
        // quoted, anything else has to be a Haxe expression.
        final newText = switch type {
            case "Bool": name + "=${1|true,false|}";
            case "String": name + "=\"$1\"";
            case _: name + "=\\${$1}";
        }

        return {
            label: name,
            kind: Field,
            detail: type,
            documentation: documentation,
            filterText: name,
            sortText: "0_" + name,
            insertTextFormat: Snippet,
            textEdit: ({range: range, newText: newText} : TextEdit)
        };

    }

    /// Hover

    public function hover(doc:TextDocument, region:MarkupRegion, tag:MarkupTag, cursor:Int,
                          token:CancellationToken, done:(hover:Null<Hover>) -> Void):Void {

        final probe = MarkupProbe.forTagIdentifier(doc.content, region, tag.name, cursor - tag.nameStart);

        withCompiler(doc, token, done, () -> {
            backend.hover(fsPath(doc.uri), probe.buffer.text, probe.offset, token, result -> {

                if (result == null || result.item == null) {
                    done(null);
                    return;
                }

                final signature = describe(result.item);
                final documentation = documentationOf(result);
                if (signature == null && documentation == null) {
                    done(null);
                    return;
                }

                final parts = [];
                if (signature != null) parts.push("```haxe\n" + signature + "\n```");
                if (documentation != null) parts.push(cleanDoc(documentation));

                done({
                    contents: ({kind: MarkupKind.Markdown, value: parts.join("\n\n")} : MarkupContent),
                    // Our own span. The compiler's points into the probe.
                    range: doc.rangeAt(tag.nameStart, tag.nameEnd)
                });
            });
        });

    }

    /**
     * The one-line signature shown in a hover.
     *
     * Deliberately the same shape vshaxe uses (`printEmptyTypeDefinition` /
     * `printClassFieldDefinition`): `class Switch`, not a fully qualified path.
     * The two extensions' hovers are stacked by VSCode with no way to suppress
     * either, so looking like one voice rather than two matters. The qualified
     * path is still where it is useful -- the `detail` of a completion item.
     */
    static function describe(item:DisplayItem):Null<String> {

        if (item.kind == "Type") {
            final type:DisplayModuleType = item.args;
            return type != null && type.path != null ? printTypeDefinition(type) : null;
        }

        if (item.kind == "ClassField") {
            final field:JsonClassField = item.args.field;
            if (field == null) return null;
            return printFieldDefinition(field, item.type != null ? item.type : field.type);
        }

        return null;

    }

    static function printTypeDefinition(type:DisplayModuleType):String {

        final parts = [];
        if (type.isPrivate) parts.push("private");
        if (type.isFinal || hasMeta(type.meta, ":final")) parts.push("final");
        if (type.isExtern) parts.push("extern");
        if (type.isAbstract) parts.push("abstract");

        parts.push(switch type.kind {
            case 0: "class";
            case 1: "interface";
            case 2: "enum";
            case 3: "abstract";
            case 4: "enum abstract";
            case _: "typedef";
        });

        parts.push(type.path.typeName + printTypeParams(type.params));
        return parts.join(" ");

    }

    /** An `@x` component is a function, so its signature is what to show. */
    static function printFieldDefinition(field:JsonClassField, type:JsonType):String {

        if (type != null && type.kind == "TFun") {
            final args:Array<Dynamic> = type.args.args;
            final printed = args == null ? [] : [for (arg in args) {
                final optional:Bool = arg.opt == true;
                (optional ? "?" : "") + arg.name + ":" + printType(arg.t, 0);
            }];
            return "function " + field.name + printTypeParams(field.params)
                + "(" + printed.join(", ") + "):" + printType(type.args.ret, 0);
        }

        // A variable, close to vshaxe's shape but without the access modifier:
        // this is read as an attribute of a tag, where whether the underlying
        // `@props` field is private is beside the point. The keyword is what
        // gives a ```haxe fence something to colour; a bare `label:String`
        // renders as plain text. The default value is the one thing a prop's
        // user most wants to know.
        final parts = [];
        if (field.scope == 0) parts.push("static");
        parts.push(field.isFinal ? "final" : "var");
        var declaration = parts.join(" ") + " " + field.name + ":" + printType(type, 0);
        if (field.expr != null && field.expr.string != null) declaration += " = " + field.expr.string;
        return declaration;

    }

    static function printTypeParams(params:Null<Array<{var name:String;}>>):String {

        if (params == null || params.length == 0) return "";
        return "<" + [for (param in params) param.name].join(", ") + ">";

    }

    /**
     * A readable rendering of a type.
     *
     * Unqualified, because a tooltip on a tag is read, not compiled. Depth is
     * bounded so a recursive or deeply nested type cannot run away.
     */
    static function printType(type:JsonType, depth:Int):String {

        if (type == null) return "Unknown";
        if (depth > 4) return "...";

        return switch type.kind {

            case "TInst" | "TAbstract" | "TEnum" | "TType":
                final path:JsonTypePath = type.args != null ? type.args.path : null;
                if (path == null) "Unknown";
                else {
                    final params:Array<JsonType> = type.args.params;
                    path.typeName + (params == null || params.length == 0
                        ? ""
                        : "<" + [for (param in params) printType(param, depth + 1)].join(", ") + ">");
                }

            case "TFun":
                final args:Array<Dynamic> = type.args.args;
                final printed = args == null || args.length == 0
                    ? "()"
                    : "(" + [for (arg in args) printType(arg.t, depth + 1)].join(", ") + ")";
                printed + " -> " + printType(type.args.ret, depth + 1);

            case "TAnonymous": "{...}";
            case "TDynamic": "Dynamic";
            case "TMono": "Unknown";
            case _: "Unknown";
        }

    }

    /**
     * Hover on an attribute of a component: the prop's type and documentation.
     *
     * A class component's `@props` field is asked about directly. An `@x`
     * function component's argument has no field to ask about, but its typed
     * signature already carries the name and type.
     */
    public function attributeHover(doc:TextDocument, region:MarkupRegion, tag:MarkupTag, attr:MarkupAttr,
                                   cursor:Int, token:CancellationToken, done:(hover:Null<Hover>) -> Void):Void {

        final file = fsPath(doc.uri);
        final range = doc.rangeAt(attr.nameStart, attr.nameEnd);

        withCompiler(doc, token, done, () -> {
            final identifier = MarkupProbe.forTagIdentifier(doc.content, region, tag.name, 1);
            backend.hover(file, identifier.buffer.text, identifier.offset, token, hovered -> {

                if (hovered == null || hovered.item == null) {
                    done(null);
                    return;
                }

                if (hovered.item.kind == "ClassField") {
                    // `@x` component: the argument is right there in the signature.
                    final signature = hovered.item.type;
                    final args:Array<Dynamic> = signature != null && signature.kind == "TFun" ? signature.args.args : null;
                    if (args != null) {
                        for (arg in args) {
                            if (arg.name == attr.name) {
                                done(hoverOf("```haxe\n" + attr.name + ":" + printType(arg.t, 0) + "\n```", range));
                                return;
                            }
                        }
                    }
                    done(null);
                    return;
                }

                final probe = MarkupProbe.forComponentProp(doc.content, region, tag.name, attr.name, cursor - attr.nameStart);
                backend.hover(file, probe.buffer.text, probe.offset, token, result -> {
                    if (result == null || result.item == null) {
                        done(null);
                        return;
                    }
                    final parts = [];
                    final signature = describe(result.item);
                    if (signature != null) parts.push("```haxe\n" + signature + "\n```");
                    final documentation = documentationOf(result);
                    if (documentation != null) parts.push(cleanDoc(documentation));
                    done(parts.length == 0 ? null : hoverOf(parts.join("\n\n"), range));
                });
            });
        });

    }

    static function hoverOf(value:String, range:Range):Hover {

        return {
            contents: ({kind: MarkupKind.Markdown, value: value} : MarkupContent),
            range: range
        };

    }

    /// Definition

    public function definition(doc:TextDocument, region:MarkupRegion, tag:MarkupTag, cursor:Int,
                               token:CancellationToken, done:(links:Null<Array<LocationLink>>) -> Void):Void {

        final probe = MarkupProbe.forTagIdentifier(doc.content, region, tag.name, cursor - tag.nameStart);
        final file = fsPath(doc.uri);
        final origin = doc.rangeAt(tag.nameStart, tag.nameEnd);

        withCompiler(doc, token, done, () -> {
            backend.definition(file, probe.buffer.text, probe.offset, token, locations -> {

                if (locations == null || locations.length == 0) {
                    done(null);
                    return;
                }

                final links:Array<LocationLink> = [];
                for (location in locations) {

                    // The common case: the component lives in another file, and
                    // that file was never rewritten, so its range is already
                    // correct.
                    if (location.file != file) {
                        final range = toRange(location.range);
                        links.push({
                            originSelectionRange: origin,
                            targetUri: pathToUri(location.file),
                            targetRange: range,
                            targetSelectionRange: range
                        });
                        continue;
                    }

                    // Same file: the range was computed against the rewritten
                    // buffer, so map it back through the splice.
                    final start = probe.buffer.originalOffsetOfDisplayPosition(location.range.start.line, location.range.start.character);
                    final end = probe.buffer.originalOffsetOfDisplayPosition(location.range.end.line, location.range.end.character);
                    final range = doc.rangeAt(start, end);
                    links.push({
                        originSelectionRange: origin,
                        targetUri: doc.uri,
                        targetRange: range,
                        targetSelectionRange: range
                    });
                }

                done(links);
            });
        });

    }

    /// Resolve

    public function resolveItem(item:CompletionItem, token:CancellationToken, done:(item:CompletionItem) -> Void):Void {

        final data:Dynamic = item.data;
        // A stale index would resolve to a different symbol entirely, so an
        // unresolved item is the only safe answer.
        if (data == null || data.index == null || data.generation != generation || !available()) {
            done(item);
            return;
        }

        backend.completionItemResolve(data.index, token, resolved -> {
            if (resolved != null && resolved.item != null && resolved.item.args != null) {
                final args = resolved.item.args;
                if (args.doc != null && item.documentation == null) item.documentation = cleanDoc(args.doc);
            }
            done(item);
        });

    }

    /// Helpers

    /**
     * Run `send` once the compiler is warm enough, or answer `null`.
     *
     * This is the only place a Haxe process can be started, and it is reached
     * only from a request already known to sit inside Wisdom markup.
     */
    function withCompiler<T>(doc:TextDocument, token:CancellationToken, done:(result:Null<T>) -> Void, send:() -> Void):Void {

        if (!available() || token.canceled) {
            done(null);
            return;
        }

        backend.whenReady(WARM_UP_GRACE_MS, ready -> {
            if (!ready || token.canceled) {
                done(null);
                return;
            }
            send();
        });

    }

    /**
     * The documentation a hover carries.
     *
     * For a type it is `result.documentation`; for a class field the compiler
     * leaves that null and puts the doc comment on the field itself.
     */
    static function documentationOf(result:HoverResult):Null<String> {

        if (result.documentation != null) return result.documentation;
        final args:Dynamic = result.item != null ? result.item.args : null;
        if (args == null) return null;
        if (args.field != null && args.field.doc != null) return args.field.doc;
        if (args.doc != null) return args.doc;
        return null;

    }

    static function hasMeta(meta:Array<JsonMetaEntry>, name:String):Bool {

        if (meta == null) return false;
        for (entry in meta) if (entry.name == name) return true;
        return false;

    }

    static function cleanDoc(documentation:String):String {

        // Strip the leading `*` of a doc comment, which arrives verbatim.
        final lines = [for (line in documentation.split("\n")) {
            final trimmed = line.ltrim();
            trimmed.startsWith("*") ? trimmed.substr(1).ltrim() : line.trim();
        }];
        return lines.join("\n").trim();

    }

    static function toRange(range:DisplayRange):Range {

        return {
            start: {line: range.start.line, character: range.start.character},
            end: {line: range.end.line, character: range.end.character}
        };

    }

    static function offsetOfLine(text:String, line:Int):Int {

        var current = 0;
        var i = 0;
        while (i < text.length && current < line) {
            if (text.charCodeAt(i) == '\n'.code) current++;
            i++;
        }
        return i;

    }

    static function readFile(path:String):Null<String> {

        return try sys.io.File.getContent(path) catch (_:Any) null;

    }

    /** `file:///a/b.hx` -> `/a/b.hx`, which is what Haxe wants. */
    public static function fsPath(uri:String):String {

        var path = uri;
        if (path.startsWith("file://")) path = path.substr(7);
        path = StringTools.urlDecode(path);
        // `file:///C:/x` decodes to `/C:/x`.
        if (~/^\/[a-zA-Z]:/.match(path)) path = path.substr(1);
        return path;

    }

    static function pathToUri(path:String):String {

        var normalised = path.replace("\\", "/");
        if (!normalised.startsWith("/")) normalised = "/" + normalised;
        // Only the path separators must survive encoding.
        final encoded = [for (segment in normalised.split("/")) StringTools.urlEncode(segment)].join("/");
        return "file://" + encoded;

    }

}
