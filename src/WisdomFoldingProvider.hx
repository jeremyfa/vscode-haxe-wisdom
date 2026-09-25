package;

import vscode.FoldingContext;
import vscode.FoldingRange;
import vscode.TextDocument;
import wisdom.lsp.markup.MarkupScanner;
import wisdom.lsp.markup.MarkupTypes;

/**
 * Folding for Wisdom markup, as a consumer of the shared markup scanner.
 *
 * The previous implementation scanned line by line and was built on the theory
 * that nested markup is written `\'<>...\'`. It is not -- and cannot be: a
 * backslash-escaped quote inside `${...}` is a syntax error, because Haxe reads
 * code again there, where a plain `'...'` literal is what is actually written.
 * Every nested region was therefore invisible to it, which is what the five
 * failed attempts recorded in `FOLDING_IMPLEMENTATION_SUMMARY.md` were chasing.
 *
 * Sharing the scanner with the language server means that class of bug can only
 * ever be fixed once.
 */
class WisdomFoldingProvider {

    public function new() {}

    public function provideFoldingRanges(
        document:TextDocument,
        context:FoldingContext,
        token:vscode.CancellationToken
    ):Array<FoldingRange> {

        final text = document.getText();

        // Cheapest possible bail-out for the overwhelmingly common case of a
        // Haxe file with no markup in it at all.
        if (text.indexOf("'<"+">") == -1) return [];

        final scan = try MarkupScanner.scan(text) catch (_:Any) return [];
        final ranges:Array<FoldingRange> = [];
        final lines = new LineIndex(text);

        for (region in scan.regions) {
            // The literal itself, so a long markup block can be collapsed whole.
            addRange(ranges, lines, region.quoteStart, region.contentEnd);
            for (tag in region.tags) collectTag(ranges, lines, region, tag);
        }

        return ranges;

    }

    function collectTag(ranges:Array<FoldingRange>, lines:LineIndex, region:MarkupRegion, tag:MarkupTag):Void {

        if (tag.closing) return;

        if (tag.closeStart != -1) {
            // From the end of the opening tag to the start of the closing one,
            // so the two delimiters both stay visible when folded.
            addRange(ranges, lines, tag.tagEnd != -1 ? tag.tagEnd : tag.tagStart, tag.closeStart);
        }
        else if (tag.tagEnd != -1) {
            // A tag with no children can still span several lines by itself
            // when its attributes are laid out one per line.
            addRange(ranges, lines, tag.tagStart, tag.tagEnd);
        }

        for (child in tag.children) collectTag(ranges, lines, region, child);

    }

    function addRange(ranges:Array<FoldingRange>, lines:LineIndex, startOffset:Int, endOffset:Int):Void {

        final start = lines.lineAt(startOffset);
        final end = lines.lineAt(endOffset);
        // VSCode folds from the end of the start line, so a range has to span
        // at least two lines to mean anything.
        if (end > start) ranges.push(new FoldingRange(start, end - 1));

    }

}

/** Offset to line number, built once per document. */
private class LineIndex {

    final starts:Array<Int> = [0];

    public function new(text:String) {
        for (i in 0...text.length) {
            if (text.charCodeAt(i) == '\n'.code) starts.push(i + 1);
        }
    }

    public function lineAt(offset:Int):Int {

        var low = 0;
        var high = starts.length - 1;
        while (low < high) {
            final mid = (low + high + 1) >> 1;
            if (starts[mid] <= offset) low = mid else high = mid - 1;
        }
        return low;

    }

}
