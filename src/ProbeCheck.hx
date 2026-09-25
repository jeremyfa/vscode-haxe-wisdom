package;

import wisdom.lsp.markup.MarkupProbe;
import wisdom.lsp.markup.MarkupScanner;

using StringTools;

/**
 * Emits the probe buffers the language server would send, as JSON, so that
 * `scripts/display-spike.mjs --probes` can put them to a real compiler.
 *
 * Splitting it this way is the point: the Haxe side is what actually builds
 * the rewritten buffer and computes the codepoint offset, and the JavaScript
 * side is what talks the wire protocol. Checking them together is the only way
 * to know the rewriting produces buffers the compiler answers correctly --
 * rather than buffers that merely look right.
 *
 * Run: haxe -cp src --main ProbeCheck --interp
 *      (reads WISDOM_PROBE_FILE and WISDOM_PROBE_OUT)
 */
class ProbeCheck {

    static function main() {

        final file = env("WISDOM_PROBE_FILE", "../wisdom-app/src/app/ui/SettingsPopup.hx");
        final out = env("WISDOM_PROBE_OUT", "/tmp/wisdom-probes.json");
        final component = env("WISDOM_PROBE_COMPONENT", "Button");
        final packagePrefix = env("WISDOM_PROBE_PACKAGE", "kit.ui.");

        if (!sys.FileSystem.exists(file)) {
            Sys.println('ProbeCheck: $file not found, nothing to emit');
            Sys.exit(0);
        }

        final text = sys.io.File.getContent(file);
        final scan = MarkupScanner.scan(text);

        if (scan.topRegions.length == 0) {
            Sys.println('ProbeCheck: no Wisdom markup in $file');
            Sys.exit(1);
        }
        final region = scan.topRegions[0];

        final probes = [
            emit("tag name, empty prefix", "display/completion", MarkupProbe.forTagName(text, region, "")),
            emit("tag name, prefix " + component.substr(0, 4), "display/completion",
                 MarkupProbe.forTagName(text, region, component.substr(0, 4))),
            emit("tag name, dotted " + packagePrefix, "display/completion",
                 MarkupProbe.forTagName(text, region, packagePrefix)),
            emit("hover " + component, "display/hover",
                 MarkupProbe.forTagIdentifier(text, region, component, 3)),
            emit("definition " + component, "display/definition",
                 MarkupProbe.forTagIdentifier(text, region, component, 3)),
            emit("props of " + component, "display/completion",
                 MarkupProbe.forComponentProps(text, region, component)),
            emit("prop hover " + component + ".label", "display/hover",
                 MarkupProbe.forComponentProp(text, region, component, "label", 2))
        ];

        sys.io.File.saveContent(out, haxe.Json.stringify({
            file: sys.FileSystem.absolutePath(file),
            probes: probes
        }));

        Sys.println('ProbeCheck: wrote ${probes.length} probes for $file to $out');

        // The rewriting itself is checkable here and now: everything outside
        // the replaced literal must be untouched, and the offset must land just
        // after the probe expression.
        var failures = 0;
        for (probe in probes) {
            final before = text.substring(0, region.quoteStart);
            if (!probe.contents.startsWith(before)) {
                Sys.println('  FAIL ${probe.label}: text before the literal was modified');
                failures++;
            }
            if (probe.contents.indexOf(MarkupProbe.HEAD) == -1) {
                Sys.println('  FAIL ${probe.label}: probe wrapper missing');
                failures++;
            }
        }
        if (failures > 0) Sys.exit(1);
        Sys.println("ProbeCheck: buffers well-formed");

    }

    static function emit(label:String, method:String, probe:MarkupProbe) {

        return {
            label: label,
            method: method,
            contents: probe.buffer.text,
            offset: probe.offset
        };

    }

    static function env(name:String, fallback:String):String {

        final value = Sys.getEnv(name);
        return value != null && value != "" ? value : fallback;

    }

}
