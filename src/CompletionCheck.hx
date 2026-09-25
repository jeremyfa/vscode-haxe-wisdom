package;

import wisdom.haxe.DisplayProtocol;
import wisdom.lsp.CancellationToken;
import wisdom.lsp.features.TypedFeatures;
import wisdom.lsp.HxmlDefines;
import wisdom.lsp.TailwindSettings;
import wisdom.lsp.features.WebData;
import wisdom.lsp.Protocol;
import wisdom.lsp.Server;
import wisdom.lsp.WisdomProtocol;

using StringTools;

/**
 * Checks the offline half of completion, end to end through the LSP server:
 * a real `didOpen`, a real `textDocument/completion`, and assertions on what
 * comes back.
 *
 * Nothing here may start a Haxe process, and the cases below say so explicitly:
 * a document with no markup, and every cursor position vshaxe already answers,
 * must come back as `null` rather than as an empty list, so the two extensions
 * never both claim a position.
 *
 * Run: haxe build.hxml (last target)
 */
class CompletionCheck {

    static var failures = 0;
    static var checks = 0;
    static var nextId = 1;

    static function main() {

        // The generated documentation files, relative to the repo root the
        // build runs from.
        WebData.basePath = "data";

        webData();
        hxmlDefines();
        tailwindSettings();

        Sys.println("\n--- completion (no Haxe compiler involved) ---");

        // Typing `<`: control flow and elements, no components (those need the compiler).
        has("function r() '<><#'", ["if", "foreach", "switch", "div", "span", "button"]);
        hasNot("function r() '<><#'", ["elseif", "else", "case", "default"]);

        // Branch tags are only offered where they are legal.
        has("function r() '<><if ${c}>a<#'", ["elseif", "else"]);
        has("function r() '<><switch ${v}><#'", ["case", "default"]);
        // Inside a `<switch>` nothing else is legal.
        hasNot("function r() '<><switch ${v}><#'", ["div", "if", "foreach"]);

        // Closing tag: the tag actually open here comes first.
        first("function r() '<><div><span></#'", "span");
        first("function r() '<><div><span></span></#'", "div");

        // Attributes of an element: the universal ones plus what HTML allows here.
        has("function r() '<><input #'", ["class", "if", "key", "placeholder", "type", "value"]);
        // `placeholder` is not valid on `<div>`, and the table knows it.
        hasNot("function r() '<><div #'", ["placeholder", "colspan"]);
        has("function r() '<><div #'", ["id", "title", "onclick", "role", "data-"]);

        // Already-used attributes drop out, except `if`/`unless`, which may repeat.
        hasNot("function r() '<><div class=\"a\" #'", ["class"]);
        has("function r() '<><div if=${a} #'", ["if", "unless"]);

        // A component's own props need the compiler, but the universal set does not.
        has("function r() '<><Button #'", ["class", "key", "if"]);
        hasNot("function r() '<><Button #'", ["placeholder", "colspan"]);

        // The Wisdom keys the compiler actually recognises: `ref` and `unmanaged`
        // are in, `attrs` -- not a key, it would become a plain prop -- is out.
        has("function r() '<><div #'", ["ref", "unmanaged"]);
        hasNot("function r() '<><div #'", ["attrs"]);
        has("function r() '<><#'", ["portal"]);

        Sys.println("\n--- backend gating ---");

        // Off the HTML backend, elements and their attributes disappear; Wisdom's
        // own tags and attributes never depend on the backend.
        hasNot("function r() '<><#'", ["div", "span", "button"], false);
        has("function r() '<><#'", ["if", "foreach", "switch", "portal"], false);
        hasNot("function r() '<><div #'", ["id", "title", "onclick", "data-"], false);
        has("function r() '<><div #'", ["class", "if", "key", "ref"], false);

        // No configuration at all means the backend is unknown, which is strict off.
        hasNot("function r() '<><#'", ["div"], true, false);
        has("function r() '<><#'", ["if", "foreach"], true, false);

        Sys.println("\n--- hover ---");

        // Wisdom's tags: a syntax fence, prose and the README link. Opening or closing.
        hoverContains("function r() '<><fore#ach ${a} ${f} />'", ["<foreach", "Wisdom README"]);
        hoverContains("function r() '<><i#f ${c}>x</if>'", ["<if", "if-statements"]);
        hoverContains("function r() '<><if ${c}>x</i#f>'", ["<if"]);
        hoverContains("function r() '<><switch ${v}><ca#se \"a\">x</case></switch>'", ["<case", "switch-statements"]);
        hoverContains("function r() '<><por#tal into=${h}>x</portal>'", ["<portal", "into"]);

        // HTML/SVG tags: description then the MDN link, no fence -- VSCode's shape.
        hoverContains("function r() '<><di#v>'", ["MDN Reference", "developer.mozilla.org/docs/Web/HTML"]);
        hoverContains("function r() '<><div></di#v>'", ["MDN Reference"]);
        hoverContains("function r() '<><cir#cle r=\"1\" />'", ["SVG/Element/circle"]);

        // Attributes: Wisdom's own first, then HTML/SVG documentation.
        hoverContains("function r() '<><div cl#ass=\"a\">'", ["<div class=", "Wisdom README"]);
        hoverContains("function r() '<><div i#f=${a}>'", ["<div if=", "conditional-attributes"]);
        hoverContains("function r() '<><Button ke#y=${k}>'", ["key-attribute"]);
        hoverContains("function r() '<><input ty#pe=\"text\">'", ["Values:", "`text`"]);
        hoverContains("function r() '<><button dis#abled=${x}>'", ["Boolean attribute"]);
        hoverContains("function r() '<><rect fi#ll=\"red\" />'", ["SVG/Attribute/fill"]);
        hoverContains("function r() '<><animate fi#ll=\"freeze\" />'", ["freeze"]);

        // Where we say nothing, so vshaxe's hover stands alone.
        hoverIsNull("function r() '<><div data-#x=\"1\">'", "an undocumented attribute");
        hoverIsNull("function r() '<><Button la#bel=\"x\">'", "a component prop needs the compiler");
        hoverIsNull("function r() '<><div class=\"a #b\">'", "inside an attribute value");
        hoverIsNull("function r() '<>${mod#el}'", "inside an interpolation");
        hoverIsNull("function r() '<>hel#lo'", "markup text");
        // Off the HTML backend the element hover goes, the Wisdom one stays.
        hoverIsNull("function r() '<><di#v>'", "an element off the HTML backend", false);
        hoverContains("function r() '<><i#f ${c}>x</if>'", ["<if"], false);

        Sys.println("\n--- attribute values ---");

        // Enumerated attributes offer their values, in source order, replacing the whole value.
        has("function r() '<><input type=\"#\">'", ["text", "button", "submit", "hidden"]);
        first("function r() '<><input type=\"#\">'", "hidden");
        has("function r() '<><form method=\"#\">'", ["get", "post"]);
        valueRangeCoversWholeValue("function r() '<><input type=\"bu#tton\">'", "button");

        // Where nothing is offered: no value set, a boolean, an interpolation, off the backend.
        isNull("function r() '<><div class=\"#\">'", "class has no value set");
        isNull("function r() '<><input disabled=\"#\">'", "a boolean attribute takes no quoted value");
        isNull("function r() '<><input type=\"te${x}#\">'", "an interpolation in the value");
        isNull("function r() '<><input type=\"#\">'", "off the HTML backend", false);

        // Insert templates follow what the attribute accepts.
        newTextIs("function r() '<><button #'", "disabled", "disabled=${1|true,false|}");
        newTextContains("function r() '<><form #'", "method", "method=\"${1|get,post");
        newTextIs("function r() '<><input #'", "type", "type=\"$1\"");            // too many values for a choice
        newTextIs("function r() '<><div #'", "unmanaged", "unmanaged");            // the one valueless attribute
        newTextIs("function r() '<><div #'", "if", "if=\\${${1:condition}}");

        // Detail shows the shape of the value; documentation arrives on resolve.
        detailIs("function r() '<><button #'", "disabled", "boolean attribute");
        detailContains("function r() '<><form #'", "method", "get | post");
        resolvedDocContains("function r() '<><#'", "div", ["MDN Reference"]);
        resolvedDocContains("function r() '<><input #'", "type", ["Values:"]);

        Sys.println("\n--- positions we must NOT answer ---");
        isNull("function r() '<>${mod#el.x}'", "inside ${}");
        isNull("function r() '<><div class=${a#}>'", "inside an attribute's ${}");
        isNull("function r() '<><div onclick=$han#dler>'", "inside $ident");
        isNull("function r() '<>hello #world'", "in markup text");
        isNull("function r() '<><!-- x# -->'", "in a comment");
        isNull("var x = foo#;", "no markup in the document at all");
        isNull("var s = 'plain ${st#r}';", "a plain interpolated string");

        hoverFormatting();

        Sys.println("");
        if (failures > 0) {
            Sys.println('CompletionCheck: $failures/$checks FAILED');
            Sys.exit(1);
        }
        Sys.println('CompletionCheck: $checks checks passed');

    }

    /**
     * The embedded HTML/SVG documentation and the loader over it.
     *
     * These pin down what `scripts/update-web-data.mjs` promises: every element
     * Wisdom accepts is described, boolean attributes are flagged, and the two
     * SVG attributes whose meaning differs between elements (`type`, `fill`)
     * kept their per-element variants through normalization.
     */
    static function webData() {

        Sys.println("--- embedded web data ---");

        // Every HTML element the renderer accepts is documented, with a link.
        var undocumented = [];
        var known = 0;
        for (name in @:privateAccess wisdom.HtmlAttributes.elements.keys()) {
            final info = WebData.tag(name);
            if (info == null) continue;   // obsolete elements VSCode no longer lists
            known++;
            if (info.description == null || info.url == null) undocumented.push(name);
        }
        report(known > 100 && undocumented.length == 0,
               'documents every known HTML element ($known found)', "html tags",
               undocumented.length > 0 ? 'undocumented: ${undocumented.join(", ")}' : 'only $known elements matched');

        final div = WebData.tag("div");
        report(div != null && div.language == Html && div.url.indexOf("developer.mozilla.org") != -1,
               "div comes from html.json with an MDN url", "tag(div)", Std.string(div));

        final circle = WebData.tag("circle");
        report(circle != null && circle.language == Svg && circle.url.indexOf("SVG/Element/circle") != -1,
               "circle comes from svg.json with an MDN url", "tag(circle)", Std.string(circle));
        report(WebData.isSvgTag("circle") && !WebData.isSvgTag("div") && !WebData.isSvgTag("title"),
               "isSvgTag: circle yes, div no, shared names count as HTML", "isSvgTag", "");
        report(WebData.tag("lineargradient") != null && WebData.tag("lineargradient").name == "linearGradient",
               "a lowercase SVG spelling resolves to the camelCase element", "tag(lineargradient)", "");

        // The four SMIL elements upstream documents with nothing but its advert.
        final animate = WebData.tag("animate");
        report(animate != null && animate.description != null && animate.description.indexOf("🧧") == -1,
               "animate has a real description (fallback applied)", "tag(animate)", Std.string(animate));

        // Value sets and boolean flags.
        final type = WebData.valuesOf("input", "type");
        report(type != null && type.indexOf("text") != -1 && type.indexOf("button") != -1 && type[0] == "hidden",
               'input.type has its value set in source order', "valuesOf(input,type)", Std.string(type));
        report(WebData.isBoolean("input", "autofocus") && WebData.isBoolean("button", "disabled") && !WebData.isBoolean("input", "type"),
               "boolean attributes are flagged, enumerated ones are not", "isBoolean", "");
        report(WebData.valuesOf("button", "disabled") == null,
               "a boolean attribute has no value set", "valuesOf(button,disabled)", "");

        // Global attributes reach every element.
        final cls = WebData.attribute("div", "class");
        report(cls != null && cls.isGlobal && cls.description != null,
               "class on div resolves to the global attribute", "attribute(div,class)", Std.string(cls));

        // The SVG collisions that must survive normalization.
        final transformType = WebData.valuesOf("animateTransform", "type");
        final turbulenceType = WebData.valuesOf("feTurbulence", "type");
        report(transformType != null && turbulenceType != null
               && transformType.indexOf("rotate") != -1 && turbulenceType.indexOf("turbulence") != -1,
               "type keeps different value sets on animateTransform and feTurbulence", "svg type collision",
               '${transformType} vs ${turbulenceType}');
        report(WebData.valuesOf("rect", "fill") == null && WebData.valuesOf("animate", "fill") != null,
               "fill: paint on rect (no set), remove|freeze on animate", "svg fill correction",
               'rect=${WebData.valuesOf("rect", "fill")} animate=${WebData.valuesOf("animate", "fill")}');
        report(WebData.attribute("rect", "fill") != null && WebData.attribute("rect", "fill").description != null,
               "rect.fill is documented through the shared entry", "attribute(rect,fill)", "");

        // Hover text, in VSCode's shape.
        final divHover = WebData.tagHoverMarkdown("div");
        report(divHover != null && divHover.indexOf("[MDN Reference](") != -1 && divHover.indexOf("```") == -1,
               "tag hover = description + MDN link, no code fence", "tagHoverMarkdown(div)", Std.string(divHover));
        final disabledHover = WebData.attributeHoverMarkdown("button", "disabled");
        report(disabledHover != null && disabledHover.indexOf("Boolean attribute") != -1,
               "boolean attribute hover explains the Wisdom spelling", "attributeHoverMarkdown(button,disabled)", Std.string(disabledHover));
        final typeHover = WebData.attributeHoverMarkdown("input", "type");
        report(typeHover != null && typeHover.indexOf("Values:") != -1 && typeHover.indexOf("`text`") != -1,
               "enumerated attribute hover lists its values", "attributeHoverMarkdown(input,type)", Std.string(typeHover));
        report(WebData.attributeHoverMarkdown("div", "data-x") == null,
               "an unknown attribute yields no hover", "attributeHoverMarkdown(div,data-x)", "");

    }

    /**
     * The define scanner that decides whether a project targets the HTML backend.
     *
     * Real fixtures on disk, because what is being checked is the path
     * resolution: includes resolve against the compiler's cwd, not the
     * including file, and `--cwd` moves that base.
     */
    static function hxmlDefines() {

        Sys.println("\n--- hxml define scanning ---");

        final tmp = Sys.getEnv("TMPDIR");
        final root = haxe.io.Path.join([tmp != null && tmp != "" ? tmp : "/tmp", "wisdom-hxml-check-" + Std.random(1000000)]);
        sys.FileSystem.createDirectory(root);
        sys.FileSystem.createDirectory(haxe.io.Path.join([root, "sub"]));
        sys.FileSystem.createDirectory(haxe.io.Path.join([root, "other"]));

        inline function write(name:String, content:String) {
            sys.io.File.saveContent(haxe.io.Path.join([root, name]), content);
        }
        inline function found(args:Array<String>):Null<DefineLocation> {
            return HxmlDefines.find(args, root, "wisdom_html");
        }
        inline function fileOf(hit:Null<DefineLocation>):String {
            return hit == null ? "<none>" : (hit.file == null ? "<arguments>" : haxe.io.Path.withoutDirectory(hit.file) + ":" + hit.line);
        }

        // The realistic shape: build.hxml includes a kit hxml that carries the define.
        write("build.hxml", "-cp src\n--main app.Main\nsub/inc.hxml\n--js out.js\n");
        write("sub/inc.hxml", "# libraries\n--library wisdom\n-D wisdom_html\n-D tracker_web_storage\n");
        var hit = found(["build.hxml"]);
        report(hit != null && hit.file != null && hit.file.endsWith("inc.hxml") && hit.line == 3,
               "finds the define in an included hxml, with its line", "build.hxml -> sub/inc.hxml", fileOf(hit));

        // Includes resolve against cwd, not against the including file: a nested
        // include written relative to sub/ must NOT be found from sub/.
        write("sub/deep.hxml", "-D wisdom_html\n");
        write("build2.hxml", "sub/nested.hxml\n");
        write("sub/nested.hxml", "deep.hxml\n");   // would be sub/deep.hxml if resolved against the including file
        report(found(["build2.hxml"]) == null,
               "an include resolves against cwd, not the including file", "build2 -> sub/nested -> deep.hxml", fileOf(found(["build2.hxml"])));

        // `--cwd` moves the base for everything after it.
        write("build3.hxml", "--cwd other\ninc.hxml\n");
        write("other/inc.hxml", "-D wisdom_html=1\n");
        hit = found(["build3.hxml"]);
        report(hit != null && hit.file != null && hit.file.indexOf("other") != -1,
               "--cwd redirects include resolution; -D name=value matches", "build3 --cwd other", fileOf(hit));

        // A cycle must terminate, and yield nothing when the define is absent.
        write("a.hxml", "b.hxml\n-cp src\n");
        write("b.hxml", "a.hxml\n");
        report(found(["a.hxml"]) == null, "an include cycle terminates", "a.hxml <-> b.hxml", fileOf(found(["a.hxml"])));

        // Comments and near-misses.
        write("c.hxml", "# -D wisdom_html is documented here but not set\n-D wisdom_htmlx\n-D wisdom\n");
        report(found(["c.hxml"]) == null, "a commented define or a longer name does not match", "c.hxml", fileOf(found(["c.hxml"])));

        // Every accepted spelling.
        write("d1.hxml", "--define wisdom_html\n");
        write("d2.hxml", "-Dwisdom_html\n");
        write("d3.hxml", "-D \"wisdom_html\"\n");
        report(found(["d1.hxml"]) != null && found(["d2.hxml"]) != null && found(["d3.hxml"]) != null,
               "--define, glued -Dname and a quoted value all match", "d1/d2/d3", "");

        // In the arguments themselves, with no file.
        hit = found(["-D", "wisdom_html", "build.hxml"]);
        report(hit != null && hit.file == null, "a define in the arguments is reported with no file", "args", fileOf(hit));
        report(found(["missing.hxml"]) == null, "a missing hxml is skipped, not an error", "missing.hxml", "");

        // Clean up.
        for (name in ["build.hxml", "build2.hxml", "build3.hxml", "a.hxml", "b.hxml", "c.hxml", "d1.hxml", "d2.hxml", "d3.hxml",
                      "sub/inc.hxml", "sub/deep.hxml", "sub/nested.hxml", "other/inc.hxml"]) {
            try sys.FileSystem.deleteFile(haxe.io.Path.join([root, name])) catch (_:Any) {}
        }
        for (dir in ["sub", "other", ""]) {
            try sys.FileSystem.deleteDirectory(haxe.io.Path.join([root, dir])) catch (_:Any) {}
        }

    }

    /**
     * The settings merge that configures Tailwind CSS IntelliSense.
     *
     * It writes into the user's workspace settings, so the property that
     * matters is that it only ever adds: nothing of theirs is removed or
     * replaced, and a second run changes nothing.
     */
    static function tailwindSettings() {

        Sys.println("\n--- tailwind settings merge ---");

        // From nothing: language mapping, defaults + classes, both regex entries.
        final fresh = TailwindSettings.merge({includeLanguages: null, classAttributes: null, classRegex: null});
        report(fresh != null
               && Reflect.field(fresh.includeLanguages, "haxe") == "html"
               && fresh.classAttributes.indexOf("class") != -1 && fresh.classAttributes.indexOf("classes") != -1
               && fresh.classRegex.length == 2,
               "fills empty settings with the mapping, default attributes + classes, two regexes", "merge(empty)", Std.string(fresh));
        report(fresh != null && TailwindSettings.isConfigured(fresh), "the merged result counts as configured", "isConfigured(merged)", "");

        // Existing values are kept: another language, a custom attribute, a user regex.
        final existing:TailwindValues = {
            includeLanguages: {plaintext: "html"},
            classAttributes: ["class", "myClass"],
            classRegex: ["clsx\\(([^)]*)\\)"]
        };
        final merged = TailwindSettings.merge(existing);
        report(merged != null
               && Reflect.field(merged.includeLanguages, "plaintext") == "html"
               && Reflect.field(merged.includeLanguages, "haxe") == "html"
               && merged.classAttributes.indexOf("myClass") != -1 && merged.classAttributes.indexOf("classes") != -1
               && merged.classRegex.length == 3 && merged.classRegex[0] == "clsx\\(([^)]*)\\)",
               "keeps the user's language, attribute and regex, adds ours after", "merge(existing)", Std.string(merged));
        report(existing.classAttributes.length == 2 && existing.classRegex.length == 1,
               "does not mutate the input", "merge input", "");

        // Idempotent: a configured set needs no change.
        report(TailwindSettings.merge(merged) == null, "a second merge changes nothing", "merge(merged)", Std.string(TailwindSettings.merge(merged)));

        // Partial: only the missing piece is added.
        final partial = TailwindSettings.merge({includeLanguages: {haxe: "html"}, classAttributes: ["class", "classes"], classRegex: null});
        report(partial != null && partial.classRegex.length == 2 && partial.classAttributes.length == 2,
               "adds only what is missing", "merge(partial)", Std.string(partial));

    }

    /**
     * The hover signature, which has to read like vshaxe's.
     *
     * Both extensions answer hover on the same position and VSCode stacks the
     * results with no way to suppress either, so a different house style is
     * immediately visible as two voices describing one thing.
     */
    static function hoverFormatting() {

        Sys.println("\n--- hover signatures (must match vshaxe's shape) ---");

        signature("class Switch", type(0, ["loreline", "app", "ui"], "Switch"));
        signature("interface Renderer", type(1, ["kit"], "Renderer"));
        signature("enum Direction", type(2, [], "Direction"));
        signature("typedef Options", type(5, ["kit"], "Options"));

        // Modifiers come before the keyword, in vshaxe's order.
        signature("final class Button", type(0, ["kit", "ui"], "Button", {isFinal: true}));
        signature("extern class Window", type(0, ["js"], "Window", {isExtern: true}));

        signature("class Store<K, V>", type(0, ["kit"], "Store", {params: [{name: "K"}, {name: "V"}]}));

        // An `@x` component is a function: its signature is the useful part.
        signature("function Row(label:String, ?count:Int):VNode", field("Row", fun([
            {name: "label", opt: false, t: inst("String")},
            {name: "count", opt: true, t: inst("Int")}
        ], inst("VNode"))));

        signature("function Icon(onpress:() -> Void):VNode", field("Icon", fun([
            {name: "onpress", opt: false, t: fun([], inst("Void"))}
        ], inst("VNode"))));

        // A `@props` field prints as a declaration, default value included and
        // access modifier left out: it is read as an attribute of a tag, and
        // without the keyword a ```haxe fence has nothing to colour.
        signature("var label:String = ''", field("label", inst("String"), {expr: {string: "''"}}));
        signature("var count:Int", field("count", inst("Int"), {isPublic: true}));
        signature("final size:Int = 16", field("size", inst("Int"), {isFinal: true, expr: {string: "16"}}));
        signature("static var shared:Bool", field("shared", inst("Bool"), {isPublic: true, scope: 0}));

    }

    static function signature(expected:String, item:DisplayItem) {

        final actual = @:privateAccess TypedFeatures.describe(item);
        report(actual == expected, 'prints "$expected"', Std.string(item.kind), 'got: $actual');

    }

    static function type(kind:Int, pack:Array<String>, name:String, ?extra:Dynamic):DisplayItem {

        final args:Dynamic = {
            path: {pack: pack, moduleName: name, typeName: name},
            isPrivate: false, isExtern: false, isFinal: false, isAbstract: false,
            meta: [], kind: kind, params: []
        };
        if (extra != null) for (key in Reflect.fields(extra)) Reflect.setField(args, key, Reflect.field(extra, key));
        return {kind: "Type", args: args};

    }

    static function field(name:String, type:JsonType, ?extra:Dynamic):DisplayItem {

        final f:Dynamic = {name: name, type: type, isPublic: false, isFinal: false, scope: 1, meta: [], params: []};
        if (extra != null) for (key in Reflect.fields(extra)) Reflect.setField(f, key, Reflect.field(extra, key));
        return {kind: "ClassField", args: {field: f}, type: type};

    }

    static inline function inst(name:String):JsonType {
        return {kind: "TInst", args: {path: {pack: [], moduleName: name, typeName: name}, params: []}};
    }

    static inline function fun(args:Array<Dynamic>, ret:JsonType):JsonType {
        return {kind: "TFun", args: {args: args, ret: ret}};
    }

    /// Driving the server

    /**
     * What the extension would push for a project on the HTML backend (or not),
     * with the compiler switched off: the offline half, which is all these
     * checks exercise.
     */
    static function testConfiguration(html:Bool):HaxeDisplayConfiguration {

        return {
            generation: 1,
            workspaceRoot: "/tmp",
            haxePath: "haxe",
            haxeEnv: {},
            serverArguments: [],
            displayArguments: null,
            source: "test",
            htmlBackend: html,
            htmlBackendSource: "test",
            settings: {
                enableTypedFeatures: false,
                haxeServerEnabled: false,
                idleShutdown: 0,
                requestTimeout: 10,
                buildCompletionCache: false,
                maxCompletionItems: 1000,
                exclude: [],
                hoverEnabled: true,
                definitionEnabled: true,
                trace: "off"
            }
        };

    }

    /**
     * `source` carries a single `#` marking the cursor.
     *
     * `html` is the backend decision the client would have made; `configured`
     * false sends no configuration at all, which is the strict state the
     * server must treat as "backend unknown".
     */
    static function complete(source:String, html:Bool = true, configured:Bool = true):Null<CompletionList> {

        final cursor = source.indexOf("#");
        final text = source.substr(0, cursor) + source.substr(cursor + 1);

        final server = new Server();
        server.onLog = (_, ?_) -> {};
        // `Message` only declares `jsonrpc`, so these go in as the wire shape.
        final initializationOptions:Dynamic = configured ? {haxeConfiguration: testConfiguration(html)} : {};
        server.handleMessage(cast {jsonrpc: "2.0", id: nextId++, method: "initialize",
                                   params: {capabilities: {}, initializationOptions: initializationOptions}});
        server.handleMessage(cast {jsonrpc: "2.0", method: "initialized", params: {}});
        server.handleMessage(cast {
            jsonrpc: "2.0", method: "textDocument/didOpen",
            params: {textDocument: {uri: "file:///Check.hx", languageId: "haxe", version: 1, text: text}}
        });

        // Offsets are what the editor sends as line/character.
        var line = 0;
        var character = 0;
        for (i in 0...cursor) {
            if (text.charCodeAt(i) == '\n'.code) { line++; character = 0; }
            else character++;
        }

        var result:Null<CompletionList> = null;
        server.handleRequestMessage(
            cast {jsonrpc: "2.0", id: nextId++, method: "textDocument/completion",
             params: {textDocument: {uri: "file:///Check.hx"}, position: {line: line, character: character}}},
            CancellationToken.NONE,
            response -> result = response.result
        );
        return result;

    }

    /** The hover's markdown at the `#`, or null. */
    static function hover(source:String, html:Bool = true, configured:Bool = true):Null<String> {

        final cursor = source.indexOf("#");
        final text = source.substr(0, cursor) + source.substr(cursor + 1);

        final server = new Server();
        server.onLog = (_, ?_) -> {};
        final initializationOptions:Dynamic = configured ? {haxeConfiguration: testConfiguration(html)} : {};
        server.handleMessage(cast {jsonrpc: "2.0", id: nextId++, method: "initialize",
                                   params: {capabilities: {}, initializationOptions: initializationOptions}});
        server.handleMessage(cast {jsonrpc: "2.0", method: "initialized", params: {}});
        server.handleMessage(cast {
            jsonrpc: "2.0", method: "textDocument/didOpen",
            params: {textDocument: {uri: "file:///Check.hx", languageId: "haxe", version: 1, text: text}}
        });

        var line = 0;
        var character = 0;
        for (i in 0...cursor) {
            if (text.charCodeAt(i) == '\n'.code) { line++; character = 0; }
            else character++;
        }

        var result:Dynamic = null;
        server.handleRequestMessage(
            cast {jsonrpc: "2.0", id: nextId++, method: "textDocument/hover",
                  params: {textDocument: {uri: "file:///Check.hx"}, position: {line: line, character: character}}},
            CancellationToken.NONE,
            response -> result = response.result
        );
        return result == null ? null : result.contents.value;

    }

    static function hoverContains(source:String, needles:Array<String>, html:Bool = true) {

        final text = hover(source, html);
        final missing = text == null ? needles : [for (needle in needles) if (text.indexOf(needle) == -1) needle];
        report(missing.length == 0, 'hover mentions ${needles.join(", ")}', source,
               text == null ? "got: no hover" : 'missing: ${missing.join(", ")} in: ${text.substr(0, 120)}');

    }

    static function hoverIsNull(source:String, why:String, html:Bool = true) {

        final text = hover(source, html);
        report(text == null, 'no hover ($why)', source, text == null ? "" : 'got: ${text.substr(0, 120)}');

    }

    static function labels(source:String, html:Bool = true, configured:Bool = true):Array<String> {

        final list = complete(source, html, configured);
        return list == null ? [] : [for (item in list.items) item.label];

    }

    /// Assertions

    static function has(source:String, expected:Array<String>, html:Bool = true, configured:Bool = true) {

        final found = labels(source, html, configured);
        final missing = [for (label in expected) if (found.indexOf(label) == -1) label];
        report(missing.length == 0, 'offers ${expected.join(", ")}', source,
               missing.length == 0 ? "" : 'missing: ${missing.join(", ")}');

    }

    static function hasNot(source:String, unexpected:Array<String>, html:Bool = true, configured:Bool = true) {

        final found = labels(source, html, configured);
        final present = [for (label in unexpected) if (found.indexOf(label) != -1) label];
        report(present.length == 0, 'omits ${unexpected.join(", ")}', source,
               present.length == 0 ? "" : 'unexpectedly offered: ${present.join(", ")}');

    }

    static function first(source:String, expected:String) {

        final list = complete(source);
        final items = list == null ? [] : list.items;
        // What the editor shows first is the lowest sortText, then the label.
        items.sort((a, b) -> {
            final sa = a.sortText != null ? a.sortText : a.label;
            final sb = b.sortText != null ? b.sortText : b.label;
            return sa < sb ? -1 : sa > sb ? 1 : 0;
        });
        final actual = items.length > 0 ? items[0].label : "<none>";
        report(actual == expected, 'suggests $expected first', source, 'got: $actual');

    }

    static function isNull(source:String, why:String, html:Bool = true) {

        final list = complete(source, html);
        report(list == null, 'answers nothing ($why)', source,
               list == null ? "" : 'got ${list.items.length} items');

    }

    static function itemFor(source:String, label:String):Null<CompletionItem> {

        final list = complete(source);
        if (list == null) return null;
        for (item in list.items) if (item.label == label) return item;
        return null;

    }

    static function newTextOf(item:Null<CompletionItem>):String {

        if (item == null) return "<no item>";
        final edit:Dynamic = item.textEdit;
        return edit != null ? edit.newText : Std.string(item.insertText);

    }

    static function newTextIs(source:String, label:String, expected:String) {

        final actual = newTextOf(itemFor(source, label));
        report(actual == expected, '$label inserts $expected', source, 'got: $actual');

    }

    static function newTextContains(source:String, label:String, needle:String) {

        final actual = newTextOf(itemFor(source, label));
        report(actual.indexOf(needle) != -1, '$label inserts ...$needle...', source, 'got: $actual');

    }

    static function detailIs(source:String, label:String, expected:String) {

        final item = itemFor(source, label);
        final actual = item == null ? "<no item>" : Std.string(item.detail);
        report(actual == expected, '$label detail is "$expected"', source, 'got: $actual');

    }

    static function detailContains(source:String, label:String, needle:String) {

        final item = itemFor(source, label);
        final actual = item == null ? "<no item>" : Std.string(item.detail);
        report(actual.indexOf(needle) != -1, '$label detail mentions "$needle"', source, 'got: $actual');

    }

    /** The first item's edit must span the whole quoted value, not just the typed prefix. */
    static function valueRangeCoversWholeValue(source:String, expectedValue:String) {

        final cursor = source.indexOf("#");
        final text = source.substr(0, cursor) + source.substr(cursor + 1);
        final open = text.lastIndexOf("\"", cursor);
        final close = text.indexOf("\"", cursor);

        final list = complete(source);
        final item = list == null || list.items.length == 0 ? null : list.items[0];
        final edit:Dynamic = item == null ? null : item.textEdit;
        final ok = edit != null
            && edit.range.start.character == open + 1
            && edit.range.end.character == close
            && text.substring(open + 1, close) == expectedValue;
        report(ok, 'replaces the whole value "$expectedValue"', source,
               edit == null ? "no edit" : 'range ${edit.range.start.character}-${edit.range.end.character}, expected ${open + 1}-$close');

    }

    /** Ask the server to resolve an item, as the editor does when it is highlighted. */
    static function resolvedDocContains(source:String, label:String, needles:Array<String>) {

        final item = itemFor(source, label);
        if (item == null) {
            report(false, 'resolves $label', source, "no such item");
            return;
        }

        final server = new Server();
        server.onLog = (_, ?_) -> {};
        server.handleMessage(cast {jsonrpc: "2.0", id: nextId++, method: "initialize",
                                   params: {capabilities: {}, initializationOptions: {haxeConfiguration: testConfiguration(true)}}});
        server.handleMessage(cast {jsonrpc: "2.0", method: "initialized", params: {}});

        var resolved:Dynamic = null;
        server.handleRequestMessage(
            cast {jsonrpc: "2.0", id: nextId++, method: "completionItem/resolve", params: item},
            CancellationToken.NONE,
            response -> resolved = response.result
        );

        final doc:Dynamic = resolved == null ? null : resolved.documentation;
        final text:String = doc == null ? null : (Std.isOfType(doc, String) ? doc : doc.value);
        final missing = text == null ? needles : [for (needle in needles) if (text.indexOf(needle) == -1) needle];
        report(missing.length == 0, 'resolving $label yields ${needles.join(", ")}', source,
               text == null ? "no documentation" : 'missing ${missing.join(", ")}');

    }

    static function report(ok:Bool, what:String, source:String, detail:String) {

        checks++;
        final shown = source.replace("\n", "\\n");
        if (ok) {
            Sys.println('  ok   $what');
        }
        else {
            failures++;
            Sys.println('  FAIL $what');
            Sys.println('         source: $shown');
            if (detail != "") Sys.println('         $detail');
        }

    }

}
