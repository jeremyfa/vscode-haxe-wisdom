package wisdom.lsp;

import wisdom.lsp.Protocol;

/**
 * A synced document: its text, a lazily built line index, and the
 * `Position` <-> offset conversions every feature needs.
 *
 * Offsets here are **UTF-16 code unit** indices, which is what a Haxe `String`
 * on the JS target is indexed by and also what LSP's `character` counts (the
 * default `positionEncoding` is `utf-16`). So the arithmetic below is a plain
 * index arithmetic on purpose -- do not "fix" it into codepoints.
 *
 * The Haxe display protocol is the one place that wants **codepoint** offsets;
 * that conversion lives in `VirtualBuffer`, at the boundary where it belongs.
 */
class TextDocument {

    public var uri(default, null):String;

    public var content(default, null):String;

    public var version(default, null):Int;

    /**
     * Whether this document contains any Wisdom markup at all.
     *
     * This is the zero-cost gate: on a project with no Wisdom markup, answering
     * a completion/hover/definition request costs exactly this one `Bool` read,
     * so no Haxe display server is ever spawned. Recomputed on every update
     * because a full-sync `didChange` replaces the whole text anyway.
     */
    public var hasMarkup(default, null):Bool;

    /** Offset of the first character of each line. Built on demand. */
    var lineStarts:Array<Int> = null;

    public function new(uri:String, content:String, version:Int = 0) {
        this.uri = uri;
        update(content, version);
    }

    public function update(content:String, version:Int = 0):Void {

        this.content = content;
        this.version = version;
        this.lineStarts = null;
        this.hasMarkup = content.indexOf("'<>") != -1;

    }

    public function offsetAt(position:Position):Int {

        final starts = getLineStarts();

        if (position.line < 0) return 0;
        if (position.line >= starts.length) return content.length;

        final lineStart = starts[position.line];
        final lineEnd = position.line + 1 < starts.length ? starts[position.line + 1] : content.length;

        var offset = lineStart + (position.character < 0 ? 0 : position.character);
        if (offset > lineEnd) offset = lineEnd;
        if (offset > content.length) offset = content.length;

        return offset;

    }

    public function positionAt(offset:Int):Position {

        if (offset <= 0) return { line: 0, character: 0 };
        if (offset > content.length) offset = content.length;

        final starts = getLineStarts();

        // Binary search for the last line starting at or before `offset`.
        var low = 0;
        var high = starts.length - 1;
        while (low < high) {
            final mid = (low + high + 1) >> 1;
            if (starts[mid] <= offset) low = mid else high = mid - 1;
        }

        return { line: low, character: offset - starts[low] };

    }

    public function rangeAt(startOffset:Int, endOffset:Int):Range {

        return {
            start: positionAt(startOffset),
            end: positionAt(endOffset)
        };

    }

    function getLineStarts():Array<Int> {

        if (lineStarts != null) return lineStarts;

        // `\r\n` needs no special case: the line starts right after the `\n`,
        // and a lone `\r` is not a line terminator in LSP's model.
        final starts = [0];
        var i = 0;
        final len = content.length;
        while (i < len) {
            if (content.charCodeAt(i) == '\n'.code) starts.push(i + 1);
            i++;
        }

        lineStarts = starts;
        return starts;

    }

}
