package wisdom.haxe;

import wisdom.haxe.DisplayProtocol;
import wisdom.haxe.HaxeDisplayServer;
import wisdom.lsp.CancellationToken;
import wisdom.lsp.HaxeBackend;
import wisdom.lsp.WisdomProtocol;

/**
 * Adapts `HaxeDisplayServer` to what the language server actually wants:
 * callbacks instead of promises, null instead of rejections, and a process
 * that only ever exists once someone has asked a question that needs it.
 *
 * The laziness is the point. Nothing here starts a compiler on activation, on
 * a file being opened, or on a workspace scan -- only on a request that has
 * already been established to sit inside Wisdom markup.
 */
class HaxeDisplayBackend implements HaxeBackend {

    public dynamic function onStatus(status:HaxeServerStatus):Void {}
    public dynamic function onLog(message:String):Void {}

    var config:Null<HaxeDisplayConfiguration> = null;
    var server:HaxeDisplayServer = null;
    var verbose:Bool = false;

    public function new() {}

    public function configure(next:Null<HaxeDisplayConfiguration>):Void {

        config = next;
        verbose = next != null && next.settings.trace == "verbose";

        if (next == null || next.displayArguments == null) {
            // Typed features just went away: stop paying for a process that can
            // no longer answer anything.
            if (server != null) {
                server.dispose();
                server = null;
            }
            onStatus({state: "stopped"});
            return;
        }

        // Only reconfigure a server that already exists. Creating one here would
        // start a compiler for a project that may never contain any markup.
        if (server != null) server.updateConfig(serverConfig(next));

    }

    public function available():Bool {

        return config != null
            && config.displayArguments != null
            && config.settings.enableTypedFeatures
            && config.settings.haxeServerEnabled;

    }

    public function whenReady(timeoutMs:Int, done:(ready:Bool) -> Void):Void {

        if (!available()) {
            done(false);
            return;
        }

        final instance = ensureServer();
        if (instance == null) {
            done(false);
            return;
        }

        var settled = false;
        inline function settle(ready:Bool) {
            if (settled) return;
            settled = true;
            done(ready);
        }

        // The first request on a cold project waits for a full compilation, so
        // it gets a deadline and an "ask me again" answer rather than a freeze.
        final timer = js.Node.setTimeout(() -> settle(false), timeoutMs);

        instance.whenWarm().then(_ -> {
            js.Node.clearTimeout(timer);
            settle(true);
            return null;
        }, error -> {
            js.Node.clearTimeout(timer);
            onLog('Haxe completion server not ready: $error');
            settle(false);
            return null;
        });

    }

    public function completion(file:String, contents:String, offset:Int, wasAutoTriggered:Bool,
                               token:CancellationToken, done:(result:Null<CompletionResult>) -> Void):Void {

        final instance = ensureServer();
        if (instance == null) {
            done(null);
            return;
        }
        settle(instance.completion(file, contents, offset, wasAutoTriggered, token), "completion", done);

    }

    public function hover(file:String, contents:String, offset:Int,
                          token:CancellationToken, done:(result:Null<HoverResult>) -> Void):Void {

        final instance = ensureServer();
        if (instance == null) {
            done(null);
            return;
        }
        settle(instance.hover(file, contents, offset, token), "hover", done);

    }

    public function definition(file:String, contents:String, offset:Int,
                               token:CancellationToken, done:(result:Null<Array<DisplayLocation>>) -> Void):Void {

        final instance = ensureServer();
        if (instance == null) {
            done(null);
            return;
        }
        settle(instance.definition(file, contents, offset, token), "definition", done);

    }

    public function completionItemResolve(index:Int, token:CancellationToken,
                                          done:(result:Null<Dynamic>) -> Void):Void {

        final instance = ensureServer();
        if (instance == null) {
            done(null);
            return;
        }
        settle(instance.completionItemResolve(index, token), "completionItem/resolve", done);

    }

    public function fileChanged(file:String):Void {
        if (server != null) server.invalidate(file);
    }

    public function fileCreated(file:String):Void {
        if (server != null) server.moduleCreated(file);
    }

    public function restart():Void {

        if (server == null) {
            // Nothing running: the next markup request starts one anyway.
            onStatus({state: "stopped"});
            return;
        }
        server.restart("requested by the user");

    }

    public function dispose():Void {

        if (server != null) {
            server.dispose();
            server = null;
        }

    }

    /// Internals

    /**
     * The compiler process, started on first use.
     *
     * This is the single place a Haxe process can come into existence, and it
     * is only ever reached from a request that the markup scanner has already
     * placed inside a `'<>...'` region.
     */
    function ensureServer():Null<HaxeDisplayServer> {

        if (!available()) return null;
        if (server != null) {
            server.ensureStarted();
            return server;
        }

        final instance = new HaxeDisplayServer(serverConfig(config));
        instance.onLog = message -> if (verbose) onLog(message);
        instance.onStateChange = state -> onStatus(switch state {
            case Stopped: {state: "stopped"};
            case Starting: {state: "starting"};
            case WarmingUp: {state: "warming"};
            case Ready: {state: "ready"};
            case Failed(message): {state: "failed", message: message};
        });

        server = instance;
        instance.ensureStarted();
        return instance;

    }

    function serverConfig(from:HaxeDisplayConfiguration):HaxeDisplayServerConfig {

        return {
            haxePath: from.haxePath,
            env: from.haxeEnv,
            cwd: from.workspaceRoot,
            serverArguments: from.serverArguments,
            displayArguments: from.displayArguments,
            requestTimeoutMs: from.settings.requestTimeout * 1000,
            idleShutdownMs: from.settings.idleShutdown * 1000,
            buildCompletionCache: from.settings.buildCompletionCache,
            maxCompletionItems: from.settings.maxCompletionItems,
            exclude: from.settings.exclude
        };

    }

    /**
     * A compiler error on a synthetic buffer is an ordinary outcome -- the
     * probe did not type-check -- so it becomes "no answer", never a failed
     * LSP request.
     */
    function settle<T>(promise:js.lib.Promise<T>, what:String, done:(result:Null<T>) -> Void):Void {

        promise.then(result -> {
            done(result);
            return null;
        }, error -> {
            if (verbose) onLog('Haxe $what failed: $error');
            done(null);
            return null;
        });

    }

}
