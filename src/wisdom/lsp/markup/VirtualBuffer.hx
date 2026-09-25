package wisdom.lsp.markup;

import wisdom.lsp.Protocol;

/**
 * The document as the Haxe compiler should see it: identical everywhere except
 * for one markup literal, replaced by a probe expression.
 *
 * Exactly one splice, which keeps the mapping trivial in both directions and,
 * more importantly, keeps the rest of the file byte-identical -- imports,
 * `using`, other members, other methods -- so the compiler's cache behaves as
 * it would for any ordinary edit.
 *
 * Note this does not expand the markup the way `MarkupToVDom` does. That
 * conversion needs a successful parse (completion happens on buffers that do
 * not parse), reorders attributes and rewrites control flow (so offsets cannot
 * be mapped back), and emits `wisdom_.Wisdom.c(...)`, which depends on a
 * `--remap` we cannot count on. None of it is needed: tag names and prop names
 * resolve at the type level.
 */
class VirtualBuffer {

    public final originalText:String;
    public final text:String;

    /** Where the replaced span started in the original document. */
    final at:Int;
    final removed:Int;
    final inserted:Int;

    public function new(originalText:String, at:Int, removed:Int, insertedText:String) {

        this.originalText = originalText;
        this.at = at;
        this.removed = removed;
        this.inserted = insertedText.length;
        this.text = originalText.substring(0, at) + insertedText + originalText.substring(at + removed);

    }

    /** Original offset -> offset in the rewritten buffer. */
    public function toVirtual(originalOffset:Int):Int {

        if (originalOffset <= at) return originalOffset;
        if (originalOffset >= at + removed) return originalOffset - removed + inserted;
        // Inside the replaced span: it no longer exists, so clamp to its start.
        return at;

    }

    /** Offset in the rewritten buffer -> original offset. */
    public function toOriginal(virtualOffset:Int):Int {

        if (virtualOffset <= at) return virtualOffset;
        if (virtualOffset >= at + inserted) return virtualOffset - inserted + removed;
        // Inside the probe, which has no original counterpart.
        return at;

    }

    /**
     * Haxe counts offsets in Unicode codepoints; a Haxe `String` on JS is
     * indexed in UTF-16 code units. They differ once anything outside the BMP
     * appears, which in UI markup means emoji -- common enough to get right.
     */
    public function codepointOffset(utf16Index:Int):Int {

        var count = 0;
        var i = 0;
        while (i < utf16Index && i < text.length) {
            final c = text.charCodeAt(i);
            // A high surrogate and its pair count as one codepoint.
            if (c >= 0xD800 && c <= 0xDBFF && i + 1 < text.length) {
                final low = text.charCodeAt(i + 1);
                if (low >= 0xDC00 && low <= 0xDFFF) i++;
            }
            count++;
            i++;
        }
        return count;

    }

    /** Codepoint offset in the rewritten buffer -> UTF-16 index. */
    public function utf16Index(codepointOffset:Int):Int {

        var count = 0;
        var i = 0;
        while (count < codepointOffset && i < text.length) {
            final c = text.charCodeAt(i);
            if (c >= 0xD800 && c <= 0xDBFF && i + 1 < text.length) {
                final low = text.charCodeAt(i + 1);
                if (low >= 0xDC00 && low <= 0xDFFF) i++;
            }
            count++;
            i++;
        }
        return i;

    }

    /**
     * A Haxe display position in the rewritten buffer -> an offset in the
     * original document.
     *
     * Haxe reports `character` as a codepoint index within the line, which is
     * not the UTF-16 column LSP wants, so both conversions happen here.
     */
    public function originalOffsetOfDisplayPosition(line:Int, character:Int):Int {

        var lineStart = 0;
        var current = 0;
        var i = 0;
        while (i < text.length && current < line) {
            if (text.charCodeAt(i) == '\n'.code) {
                current++;
                lineStart = i + 1;
            }
            i++;
        }
        if (current < line) return toOriginal(text.length);

        // Walk `character` codepoints from the start of the line.
        var offset = lineStart;
        var counted = 0;
        while (counted < character && offset < text.length) {
            final c = text.charCodeAt(offset);
            if (c == '\n'.code) break;
            if (c >= 0xD800 && c <= 0xDBFF && offset + 1 < text.length) {
                final low = text.charCodeAt(offset + 1);
                if (low >= 0xDC00 && low <= 0xDFFF) offset++;
            }
            counted++;
            offset++;
        }

        return toOriginal(offset);

    }

    /** True when this offset lands in the probe rather than in the user's code. */
    public function isSynthetic(virtualOffset:Int):Bool {

        return virtualOffset > at && virtualOffset < at + inserted;

    }

}
