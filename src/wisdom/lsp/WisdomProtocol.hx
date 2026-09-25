package wisdom.lsp;

/**
 * Types shared between the extension (which can read VSCode settings and talk
 * to vshaxe) and the language server (which owns the Haxe display server).
 *
 * The configuration is pushed to the server rather than pulled: pulling would
 * mean the server re-deriving the active hxml configuration, resolving
 * `haxe.executable`'s per-OS overrides and glob-matching the active editor,
 * all without the `vscode` module -- and it would add a round trip on the
 * completion hot path.
 */

/** Client -> server. Sent as `initializationOptions` and then on every change. */
typedef HaxeDisplayConfiguration = {

    /** Monotonic. The server ignores anything older than what it holds. */
    var generation:Int;

    /** Workspace folder, as a filesystem path. Passed to Haxe as `--cwd`. */
    var workspaceRoot:String;

    var haxePath:String;

    var haxeEnv:haxe.DynamicAccess<String>;

    /** `haxe.displayServer.arguments`, passed at spawn time. */
    var serverArguments:Array<String>;

    /**
     * The project's compiler arguments, usually just `["build.hxml"]`.
     * Null means no configuration could be resolved: typed features stay off
     * and no Haxe process is ever started.
     */
    var displayArguments:Null<Array<String>>;

    /** Where `displayArguments` came from, for the output channel. */
    var source:String;

    /**
     * Whether the markup targets Wisdom's HTML backend, and therefore whether
     * HTML/SVG tags, attributes, values and their documentation are offered.
     * Decided on the client (setting + hxml scan); the server holds no policy.
     */
    var htmlBackend:Bool;

    /** "setting:on" | "setting:off" | "detected:<file>" | "detected:arguments" | "not-detected" | "no-configuration" */
    var htmlBackendSource:String;

    var settings:WisdomSettings;

}

typedef WisdomSettings = {
    var enableTypedFeatures:Bool;
    var haxeServerEnabled:Bool;
    /** Seconds; 0 disables the idle shutdown. */
    var idleShutdown:Int;
    /** Seconds of silence from the compiler before giving up and restarting. */
    var requestTimeout:Int;
    var buildCompletionCache:Bool;
    var maxCompletionItems:Int;
    var exclude:Array<String>;
    var hoverEnabled:Bool;
    var definitionEnabled:Bool;
    /** "off" | "messages" | "verbose" */
    var trace:String;
}

/** Server -> client, to drive the status bar and the warm-up progress. */
typedef HaxeServerStatus = {
    /** "stopped" | "starting" | "warming" | "ready" | "failed" */
    var state:String;
    var ?message:String;
}

class WisdomMethods {
    public static inline var DidChangeHaxeConfiguration = "wisdom/didChangeHaxeConfiguration";
    public static inline var RestartHaxeServer = "wisdom/restartHaxeServer";
    public static inline var HaxeServerStatus = "wisdom/haxeServerStatus";
}
