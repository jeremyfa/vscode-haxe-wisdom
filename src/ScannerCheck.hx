package;

import wisdom.lsp.markup.HaxeStringLexer;
import wisdom.lsp.markup.MarkupScanner;
import wisdom.lsp.markup.MarkupTypes;

using StringTools;

/**
 * Checks the Wisdom markup scanner.
 *
 * Two halves, and both matter:
 *
 *  - Targeted cases, written with a `|` where the cursor is, asserting the
 *    exact `CursorContext`. These are the specification.
 *  - A sweep of every offset of every file in a real corpus, asserting only
 *    that nothing throws and that regions come out at the right depth. The
 *    point is that completion runs on buffers mid-edit, so "never throws" is a
 *    correctness property, not a nicety.
 *
 * Run: haxe build.hxml   (last target), or
 *      haxe -cp src --main ScannerCheck --interp [extra files or dirs...]
 */
class ScannerCheck {

    static var failures = 0;
    static var checks = 0;

    static function main() {

        runCases();
        sweepCorpus();

        Sys.println("");
        if (failures > 0) {
            Sys.println('ScannerCheck: $failures/$checks FAILED');
            Sys.exit(1);
        }
        Sys.println('ScannerCheck: $checks checks passed');

    }

    /// Targeted cases

    static function runCases() {

        Sys.println("--- cursor contexts ---");

        // A bare `<`: the tag name is empty and completion should offer everything.
        ctx("'<><|'", "InOpenTagName ''");
        ctx("'<><di|v>'", "InOpenTagName 'di'");
        ctx("'<><Butt|'", "InOpenTagName 'Butt'");
        ctx("'<><kit.ui.Bu|'", "InOpenTagName 'kit.ui.Bu'");

        // Closing tags are a different suggestion (the expected tag), so they
        // have to be distinguishable.
        ctx("'<><div></di|v>'", "InOpenTagName(closing) 'di'");
        ctx("'<><div></|'", "InOpenTagName(closing) ''");

        // Attribute names, including the whitespace position where one starts.
        ctx("'<><Button |/>'", "InAttrName ''");
        ctx("'<><Button lab|el=\"x\" />'", "InAttrName 'lab'");
        ctx("'<><Button label=\"x\" |/>'", "InAttrName '' used=label");
        // `if`/`unless` may repeat, so they never count as already used.
        ctx("'<><div if=${a} class=\"c\" |/>'", "InAttrName '' used=class");

        // Inside a double-quoted attribute value, but outside any ${} in it.
        ctx("'<><div class=\"a| b\">'", "InAttrStringValue class");

        // The bail-outs. Everything here is already answered by vshaxe.
        ctx("'<><div class=${mod|el.x}>'", "InHaxeExpr");
        ctx("'<>${mod|el.x}'", "InHaxeExpr");
        ctx("'<><div class=\"a ${b|.c} d\">'", "InHaxeExpr");
        ctx("'<><div onclick=$han|dler>'", "InHaxeExpr");
        ctx("'<>text <!-- comm|ent --> more'", "InComment");
        ctx("'<>text // comm|ent\\n'", "InComment");
        ctx("var x = 1; |", "OutsideMarkup");
        ctx("'plain ${st|ring}'", "OutsideMarkup");

        // `$$` is a literal dollar, not an interpolation (the Haxe lexer rule).
        ctx("'<>$$|foo'", "InText");
        ctx("'<>hello |world'", "InText");

        Sys.println("\n--- structure ---");

        // Nested markup inside a foreach lambda: unescaped, which is how it is
        // actually written, and what the old folding provider never handled.
        structure(
            "'<><foreach ${items} ${(i, item) -> '<><Row label=${item.name} />'} />'",
            [{depth: 0, tags: ["foreach"]}, {depth: 1, tags: ["Row"]}]
        );

        // A nested region inside a plain (non-markup) string still counts.
        structure(
            "'<><div>${cond ? '<><b>y</b>' : null}</div>'",
            [{depth: 0, tags: ["div", "div"]}, {depth: 1, tags: ["b", "b"]}]
        );

        // A plain string nested inside an interpolation: its own `${}` belongs
        // to it, not to the enclosing region.
        structure("'<><div style=${{ padding: '${n}px' }}></div>'", [{depth: 0, tags: ["div", "div"]}]);

        // An apostrophe inside markup text must not end the region early; it is
        // escaped in the source, which the scanner has to step over.
        structure("'<><p>it\\'s fine</p>'", [{depth: 0, tags: ["p", "p"]}]);

        // Unterminated, which is the normal state while typing.
        structure("'<><div><Butt", [{depth: 0, tags: ["div", "Butt"]}]);

        // Bare literal case patterns are values, not attributes, and not errors.
        structure("'<><switch ${v}><case 3>x</case><case true>y</case><case _>z</case></switch>'",
                  [{depth: 0, tags: ["switch", "case", "case", "case", "case", "case", "case", "switch"]}]);
        noIssues("'<><switch ${v}><case 3>a</case><case 0xFF>b</case><case 1.5e-3>c</case><case null>d</case></switch>'");
        noAttrs("'<><case true>x</case>'");

        Sys.println("\n--- tag stack ---");
        stack("'<><div><span>|</span></div>'", ["div", "span"]);
        stack("'<><if ${c}><div>|</div></if>'", ["if", "div"]);
        // `<else>` continues the `<if>` rather than nesting inside it.
        stack("'<><if ${c}>a<else>|b</if>'", ["else"]);
        stack("'<><switch ${v}><case 1>|</case></switch>'", ["switch", "case"]);

    }

    /**
     * `source` carries a single `|` marking the cursor. It is removed before
     * scanning, so offsets line up with what the editor would send.
     */
    static function ctx(source:String, expected:String) {

        final cursor = source.indexOf("|");
        final text = source.substr(0, cursor) + source.substr(cursor + 1);
        final scan = MarkupScanner.scan(text);

        final actual = switch MarkupScanner.contextAt(scan, cursor) {
            case OutsideMarkup: "OutsideMarkup";
            case InText(_, _): "InText";
            case InOpenTagName(_, _, prefix, _, isClosing):
                (isClosing ? "InOpenTagName(closing) " : "InOpenTagName ") + "'" + prefix + "'";
            case InAttrName(_, _, prefix, _, used):
                "InAttrName '" + prefix + "'" + (used.length > 0 ? " used=" + used.join(",") : "");
            case InAttrStringValue(_, _, attr): "InAttrStringValue " + attr.name;
            case InHaxeExpr(_, _): "InHaxeExpr";
            case InComment(_, _): "InComment";
        }

        report(actual == expected, '$actual', expected, source);

    }

    static function structure(text:String, expected:Array<{depth:Int, tags:Array<String>}>) {

        final scan = MarkupScanner.scan(text);
        final actual = [for (region in scan.regions) {
            depth: region.depth,
            tags: [for (tag in region.tags) tag.name]
        }];

        final describe = (v:Array<{depth:Int, tags:Array<String>}>) ->
            [for (r in v) 'depth${r.depth}[${r.tags.join(" ")}]'].join(" ");

        report(describe(actual) == describe(expected), describe(actual), describe(expected), text);

    }

    static function noIssues(text:String) {

        final scan = MarkupScanner.scan(text);
        final issues = [for (region in scan.regions) for (issue in region.issues) issue.message];
        report(issues.length == 0, issues.length == 0 ? "no issues" : issues.join("; "), "no issues", text);

    }

    /** A tag whose body is only bare literals must end up with no attributes. */
    static function noAttrs(text:String) {

        final scan = MarkupScanner.scan(text);
        final attrs = [for (region in scan.regions) for (tag in region.tags) for (attr in tag.attrs) attr.name];
        report(attrs.length == 0, attrs.length == 0 ? "no attributes" : "attributes: " + attrs.join(","), "no attributes", text);

    }

    static function stack(source:String, expected:Array<String>) {

        final cursor = source.indexOf("|");
        final text = source.substr(0, cursor) + source.substr(cursor + 1);
        final scan = MarkupScanner.scan(text);
        final actual = [for (tag in MarkupScanner.tagStackAt(scan, cursor)) tag.name];

        report(actual.join(">") == expected.join(">"), actual.join(">"), expected.join(">"), source);

    }

    static function report(ok:Bool, actual:String, expected:String, source:String) {

        checks++;
        if (ok) {
            Sys.println('  ok   ${trim(source)}');
        }
        else {
            failures++;
            Sys.println('  FAIL ${trim(source)}');
            Sys.println('         expected: $expected');
            Sys.println('         actual:   $actual');
        }

    }

    static inline function trim(s:String):String {
        final oneLine = s.replace("\n", "\\n");
        return oneLine.length > 74 ? oneLine.substr(0, 71) + "..." : oneLine;
    }

    /// Corpus sweep

    static function sweepCorpus() {

        Sys.println("\n--- corpus sweep (every offset of every file) ---");

        final corpusEnv = Sys.getEnv("WISDOM_SCANNER_CORPUS");
        final roots = corpusEnv != null && corpusEnv != "" ? corpusEnv.split(":") : [
            "TEST_FOLDING.hx",
            "TEST_SIMPLE_FOLDING.hx",
            "../wisdom/test",
            "../wisdom-kit/src/kit/ui",
            "../wisdom-app/src/app",
            "../loreline-writer/src/loreline/app/ui"
        ];

        var files = 0;
        var regions = 0;
        var tags = 0;
        var issues = 0;
        var skipped = [];

        for (root in roots) {
            if (!sys.FileSystem.exists(root)) { skipped.push(root); continue; }
            for (path in collect(root)) {
                final text = try sys.io.File.getContent(path) catch (_:Any) continue;
                files++;

                var scan = null;
                try {
                    scan = MarkupScanner.scan(text);
                }
                catch (e:Any) {
                    failures++;
                    Sys.println('  FAIL scan threw on $path: $e');
                    continue;
                }
                checks++;

                regions += scan.regions.length;
                for (region in scan.regions) {
                    tags += region.tags.length;
                    issues += region.issues.length;
                }

                // Every region must actually start on a `'<>` literal, and a
                // nested one must sit inside its parent.
                for (region in scan.regions) {
                    checks++;
                    // Both passes walk this list with a forward-only cursor, so
                    // sorted and non-overlapping is a load-bearing invariant.
                    var previousEnd = -1;
                    for (interp in region.interps) {
                        if (interp.start < previousEnd) {
                            failures++;
                            Sys.println('  FAIL interps out of order or overlapping at ${interp.start} in $path');
                            break;
                        }
                        previousEnd = interp.end;
                    }
                    if (text.substr(region.quoteStart, 3) != "'<>") {
                        failures++;
                        Sys.println('  FAIL region at ${region.quoteStart} in $path does not start on a markup literal');
                    }
                    if (region.parent != null
                        && !(region.quoteStart > region.parent.contentStart && region.contentEnd <= region.parent.contentEnd)) {
                        failures++;
                        Sys.println('  FAIL nested region at ${region.quoteStart} in $path escapes its parent');
                    }
                }

                var threw = false;
                for (offset in 0...text.length + 1) {
                    try MarkupScanner.contextAt(scan, offset)
                    catch (e:Any) {
                        failures++;
                        threw = true;
                        Sys.println('  FAIL contextAt threw at $offset in $path: $e');
                        break;
                    }
                }
                checks++;
                if (threw) continue;
            }
        }

        Sys.println('  $files files, $regions regions, $tags tags, $issues issues, no exceptions');
        if (skipped.length > 0) Sys.println('  (skipped, not present: ${skipped.join(", ")})');

    }

    static function collect(root:String):Array<String> {

        if (!sys.FileSystem.isDirectory(root)) return root.endsWith(".hx") ? [root] : [];

        var found = [];
        for (entry in sys.FileSystem.readDirectory(root)) {
            found = found.concat(collect(haxe.io.Path.join([root, entry])));
        }
        return found;

    }

}
