package wisdom.lsp;

/**
 * A transport-neutral cancellation token.
 *
 * `vscode-languageserver` already parses `$/cancelRequest` and hands every
 * request handler its own token, so we never implement that notification
 * ourselves. `WisdomServer` adapts the library's token into one of these so
 * that `Server` and the feature handlers stay free of any Node/LSP-library
 * dependency.
 *
 * On cancellation, handlers resolve `null` rather than rejecting with
 * `RequestCancelled`: some VSCode versions surface a rejected request as an
 * error toast, and an empty answer is always safe for us.
 */
class CancellationToken {

    /** A token that is never cancelled. Use for internal, non-cancellable work. */
    public static final NONE:CancellationToken = new CancellationToken();

    public var canceled(default, null):Bool = false;

    var listeners:Array<()->Void> = null;

    public function new() {}

    public function cancel():Void {

        if (canceled) return;
        canceled = true;

        final toCall = listeners;
        listeners = null;
        if (toCall != null) {
            for (listener in toCall) {
                try listener() catch (_:Any) {}
            }
        }

    }

    /**
     * Call `listener` when this token is cancelled, or right away if it already was.
     */
    public function onCancel(listener:()->Void):Void {

        if (canceled) {
            try listener() catch (_:Any) {}
            return;
        }

        if (listeners == null) listeners = [];
        listeners.push(listener);

    }

}
