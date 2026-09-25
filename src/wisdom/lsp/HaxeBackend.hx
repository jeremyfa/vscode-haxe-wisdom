package wisdom.lsp;

import wisdom.haxe.DisplayProtocol;
import wisdom.lsp.WisdomProtocol;

/**
 * What the language server needs from a Haxe compiler, and nothing more.
 *
 * `Server` talks to this rather than to `HaxeDisplayServer` directly for two
 * reasons: the real implementation is Node-only, while the server's offline
 * half has to stay compilable (and testable) anywhere; and a null backend is
 * then the honest representation of "no Haxe configuration resolved", which is
 * a state the extension genuinely runs in.
 *
 * Callbacks rather than promises for the same reason -- `js.lib.Promise` does
 * not exist outside JavaScript targets.
 *
 * Every method reports failure by answering null. Nothing here may throw: a
 * compiler error on one of our synthetic buffers is an ordinary outcome, not
 * something to surface to the user.
 */
interface HaxeBackend {

    function configure(config:Null<HaxeDisplayConfiguration>):Void;

    /** False when no configuration resolved, or typed features are switched off. */
    function available():Bool;

    /**
     * Wait for the compiler to be warm, but not for long.
     *
     * Calls `done(true)` if it is ready within `timeoutMs`, `done(false)`
     * otherwise -- in which case the caller answers `isIncomplete` and the
     * editor asks again on the next keystroke, rather than blocking on a cache
     * build that can take seconds.
     */
    function whenReady(timeoutMs:Int, done:(ready:Bool) -> Void):Void;

    function completion(file:String, contents:String, offset:Int, wasAutoTriggered:Bool,
                        token:CancellationToken, done:(result:Null<CompletionResult>) -> Void):Void;

    function hover(file:String, contents:String, offset:Int,
                   token:CancellationToken, done:(result:Null<HoverResult>) -> Void):Void;

    function definition(file:String, contents:String, offset:Int,
                        token:CancellationToken, done:(result:Null<Array<DisplayLocation>>) -> Void):Void;

    function completionItemResolve(index:Int, token:CancellationToken,
                                   done:(result:Null<Dynamic>) -> Void):Void;

    function fileChanged(file:String):Void;

    function fileCreated(file:String):Void;

    function restart():Void;

    function dispose():Void;

}
