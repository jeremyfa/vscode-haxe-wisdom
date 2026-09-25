package wisdom.lsp;

import haxe.io.Path;

using StringTools;

typedef DefineLocation = {
    /** The HXML file the define was found in, or null when it was in the arguments themselves. */
    var file:Null<String>;
    /** 1-based line in that file, 0 for the arguments. */
    var line:Int;
}

/**
 * Finds a `-D name` in a set of compiler arguments, following the HXML files
 * they include.
 *
 * This is how the extension learns which Wisdom backend a project targets:
 * `-D wisdom_html` usually lives not in `build.hxml` but in a file it includes
 * (`lib/wisdom-kit/kit.hxml`), so a look at the top-level arguments is not
 * enough. Includes are resolved the way Haxe resolves them -- against the
 * compiler's working directory, not against the including file.
 *
 * Deliberately not a full HXML parser: `-lib`, `-cp`, `--macro` and everything
 * else are skipped, which means a define contributed by a library's own
 * `extraParams.hxml` is invisible here. Wisdom's defines none, so this is the
 * right trade for a scanner that runs on every configuration refresh.
 *
 * Pure Haxe (`sys.io.File`), so it compiles for the extension, the language
 * server and the `--interp` checks alike.
 */
class HxmlDefines {

    public static function find(arguments:Array<String>, cwd:String, define:String, maxDepth:Int = 8):Null<DefineLocation> {

        final scanner = new HxmlDefines(define, maxDepth);
        return scanner.scanTokens(arguments, cwd, null, [], 0);

    }

    final define:String;
    final maxDepth:Int;
    final visited:Map<String, Bool> = [];

    function new(define:String, maxDepth:Int) {
        this.define = define;
        this.maxDepth = maxDepth;
    }

    /**
     * Walk one token list. `file` is the HXML these tokens came from, `lines`
     * the source line of each token, both null for the arguments.
     */
    function scanTokens(tokens:Array<String>, cwd:String, file:Null<String>, lines:Array<Int>, depth:Int):Null<DefineLocation> {

        var i = 0;
        while (i < tokens.length) {
            final token = tokens[i];
            final line = lines.length > i ? lines[i] : 0;

            // `-D name`, `-D name=value`, `--define name`
            if (token == "-D" || token == "--define") {
                if (i + 1 < tokens.length && matches(tokens[i + 1])) return {file: file, line: line};
                i += 2;
                continue;
            }

            // Glued form: `-Dname`
            if (token.startsWith("-D") && token.length > 2) {
                if (matches(token.substr(2))) return {file: file, line: line};
                i++;
                continue;
            }

            // Haxe resolves every later relative path against this instead.
            if (token == "--cwd" || token == "-C") {
                if (i + 1 < tokens.length) cwd = resolve(cwd, tokens[i + 1]);
                i += 2;
                continue;
            }

            if (token.endsWith(".hxml")) {
                final found = scanFile(resolve(cwd, token), cwd, depth + 1);
                if (found != null) return found;
                i++;
                continue;
            }

            i++;
        }

        return null;

    }

    function scanFile(path:String, cwd:String, depth:Int):Null<DefineLocation> {

        if (depth > maxDepth) return null;

        // Canonical when the file exists, so `a/../b.hxml` and `b.hxml` are one visit.
        final key = try sys.FileSystem.fullPath(path) catch (_:Any) Path.normalize(path);
        if (visited.exists(key)) return null;
        visited.set(key, true);

        final content = try sys.io.File.getContent(path) catch (_:Any) return null;

        final tokens:Array<String> = [];
        final lines:Array<Int> = [];
        var lineNumber = 0;
        for (raw in content.split("\n")) {
            lineNumber++;
            final line = raw.trim();
            if (line == "" || line.startsWith("#")) continue;
            for (token in tokenize(line)) {
                tokens.push(token);
                lines.push(lineNumber);
            }
        }

        return scanTokens(tokens, cwd, path, lines, depth);

    }

    /** Split on whitespace, keeping double-quoted spans together. */
    static function tokenize(line:String):Array<String> {

        final tokens = [];
        var current = new StringBuf();
        var hasCurrent = false;
        var inQuotes = false;

        for (i in 0...line.length) {
            final c = line.charAt(i);
            if (c == '"') {
                inQuotes = !inQuotes;
                hasCurrent = true;
                continue;
            }
            if (!inQuotes && (c == " " || c == "\t")) {
                if (hasCurrent) {
                    tokens.push(current.toString());
                    current = new StringBuf();
                    hasCurrent = false;
                }
                continue;
            }
            current.add(c);
            hasCurrent = true;
        }
        if (hasCurrent) tokens.push(current.toString());

        return tokens;

    }

    inline function matches(value:String):Bool {
        return value == define || value.startsWith(define + "=");
    }

    static function resolve(cwd:String, path:String):String {
        return Path.isAbsolute(path) ? Path.normalize(path) : Path.normalize(Path.join([cwd, path]));
    }

}
