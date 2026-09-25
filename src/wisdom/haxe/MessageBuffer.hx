package wisdom.haxe;

import js.node.Buffer;

/**
 * Reassembles Haxe's length-prefixed frames from a stream.
 *
 * A frame is an `int32` little-endian length -- which excludes the four header
 * bytes -- followed by that many bytes of UTF-8. Frames arrive on **stderr**;
 * the compiler's stdout is log output only.
 */
class MessageBuffer {

    var data:Buffer = Buffer.alloc(0);

    public function new() {}

    public function append(chunk:Buffer):Void {
        data = Buffer.concat([data, chunk]);
    }

    /** The next complete frame, or null while one is still arriving. */
    public function tryRead():Null<String> {

        if (data.length < 4) return null;

        final length = data.readInt32LE(0);
        if (data.length < 4 + length) return null;

        final payload = data.slice(4, 4 + length).toString();
        data = data.slice(4 + length);
        return payload;

    }

    /** Whatever is buffered, for reporting a crash mid-frame. */
    public function drain():String {

        final rest = data.toString();
        data = Buffer.alloc(0);
        return rest;

    }

    public function clear():Void {
        data = Buffer.alloc(0);
    }

}
