package wisdom.haxe;

import haxe.DynamicAccess;
import haxe.Json;
import js.lib.Promise;
import js.node.Buffer;
import js.node.ChildProcess;
import wisdom.haxe.DisplayProtocol;
import wisdom.lsp.CancellationToken;

using StringTools;

enum HaxeServerState {
    Stopped;
    Starting;
    WarmingUp;
    Ready;
    Failed(message:String);
}

typedef HaxeDisplayServerConfig = {
    var haxePath:String;
    var env:DynamicAccess<String>;
    var cwd:String;
    /** `haxe.displayServer.arguments`, passed once at spawn. */
    var serverArguments:Array<String>;
    /** The project's own arguments, e.g. `["build.hxml"]`. */
    var displayArguments:Array<String>;
    var ?requestTimeoutMs:Int;
    var ?idleShutdownMs:Int;
    var ?buildCompletionCache:Bool;
    var ?maxCompletionItems:Int;
    var ?exclude:Array<String>;
}

/**
 * Our own `haxe --wait stdio`.
 *
 * Deliberately a second compiler process rather than a tap into vshaxe's: the
 * port vshaxe exposes reads one TCP chunk, splits it on newlines and mutates
 * its own invalidation bookkeeping, none of which survives requests that carry
 * a rewritten copy of the file.
 *
 * Two behaviours here are not obvious and are load-bearing:
 *
 *  - `-D completion` is on every invocation, cache build included. Macros
 *    that pick their display branch with a compile-time `#if display` get it
 *    frozen by the compilation server, which reuses the macro context: after
 *    the cache build (a normal compilation) they would stay in build mode.
 *    wisdom tests `Context.defined("display")` at run time and no longer needs
 *    this, but tracker still uses `#if` (its `unobservedX` fields would show up
 *    as `@props`), as do older wisdom versions, which would convert the markup
 *    during completion and break it for the whole file.
 *  - the timeout is an **inactivity** timeout. A `--display` call cannot be
 *    cancelled, so a wall-clock deadline would kill legitimately slow
 *    compilations in a restart loop.
 */
class HaxeDisplayServer {

    static inline var DEFAULT_REQUEST_TIMEOUT_MS = 10000;
    static inline var STARTUP_TIMEOUT_MS = 30000;
    static inline var CACHE_BUILD_TIMEOUT_MS = 180000;
    static inline var MAX_CRASHES = 5;
    static inline var HEALTHY_UPTIME_MS = 60000;

    /** Frame markers in a response payload. */
    static inline var LOG_LINE = 1;
    static inline var ERROR_LINE = 2;

    public var state(default, null):HaxeServerState = Stopped;
    public var haxeVersion(default, null):{major:Int, minor:Int, patch:Int} = null;
    public var supportedMethods(default, null):Array<String> = [];

    public dynamic function onStateChange(state:HaxeServerState):Void {}
    public dynamic function onLog(message:String):Void {}

    var config:HaxeDisplayServerConfig;

    var child:Dynamic = null;
    var buffer:MessageBuffer = new MessageBuffer();
    var lastErrorOutput:String = "";

    var nextId:Int = 1;
    var queue:Array<DisplayRequest> = [];
    var current:DisplayRequest = null;
    var inactivityTimer:Dynamic = null;
    var idleTimer:Dynamic = null;

    var startPromise:Promise<Dynamic> = null;
    var warmPromise:Promise<Dynamic> = null;
    var crashes:Int = 0;
    var startedAt:Float = 0;
    var disposed:Bool = false;

    public function new(config:HaxeDisplayServerConfig) {
        this.config = config;
    }

    /// Lifecycle

    /** Idempotent. Resolves once the handshake is done and requests can be sent. */
    public function ensureStarted():Promise<Dynamic> {

        if (disposed) return Promise.reject("disposed");
        if (startPromise != null) return startPromise;

        startPromise = doStart();
        return startPromise;

    }

    /** Resolves once the cache build and classpath scan have finished. */
    public function whenWarm():Promise<Dynamic> {

        return ensureStarted().then(_ -> warmPromise != null ? warmPromise : Promise.resolve(null));

    }

    function doStart():Promise<Dynamic> {

        setState(Starting);

        final version = detectVersion();
        if (version == null) {
            final message = 'Haxe executable not found or not runnable: ${config.haxePath}';
            setState(Failed(message));
            return Promise.reject(message);
        }
        haxeVersion = version;

        try spawnProcess()
        catch (e:Any) {
            final message = 'Could not start Haxe: $e';
            setState(Failed(message));
            return Promise.reject(message);
        }

        return callMethod(DisplayMethods.Initialize, {
            supportsResolve: true,
            exclude: config.exclude != null ? config.exclude : [],
            maxCompletionItems: config.maxCompletionItems != null ? config.maxCompletionItems : 1000
        }, {withProject: false, timeoutMs: STARTUP_TIMEOUT_MS})
        .then((result:Dynamic) -> {
            if (result != null && result.methods != null) supportedMethods = result.methods;
            // Module checks cost a stat per module per request, and we invalidate
            // the one file we rewrite explicitly anyway.
            return callMethod(DisplayMethods.ServerConfigure,
                {noModuleChecks: true, legacyCompletion: false},
                {withProject: false, timeoutMs: STARTUP_TIMEOUT_MS});
        })
        .then(_ -> {
            setState(Ready);
            warmPromise = warmUp();
            return null;
        })
        .catchError(e -> {
            final message = 'Haxe completion server failed to start: $e';
            onLog(message);
            setState(Failed(message));
            throw e;
        });

    }

    function warmUp():Promise<Dynamic> {

        setState(WarmingUp);

        var chain:Promise<Dynamic> = Promise.resolve(null);

        if (config.buildCompletionCache != false) {
            final args = ["--no-output", "--each", "--no-output", "-D", "message.no-color", "-D", "completion"]
                .concat(config.displayArguments);
            chain = chain.then(_ -> callRaw("cache build", args, CACHE_BUILD_TIMEOUT_MS));
        }

        // Makes every type on the class path visible to toplevel completion.
        chain = chain.then(_ -> callMethod(DisplayMethods.ServerReadClassPaths, {}, {timeoutMs: CACHE_BUILD_TIMEOUT_MS}));

        return chain
            .then(_ -> {
                setState(Ready);
                return null;
            })
            .catchError(e -> {
                // A cold server still answers, just slower, so this is not fatal.
                onLog('Haxe completion server warm-up failed (continuing): $e');
                setState(Ready);
                return null;
            });

    }

    function detectVersion():Null<{major:Int, minor:Int, patch:Int}> {

        try {
            final result = ChildProcess.spawnSync(config.haxePath, ["-version"],
                cast {cwd: config.cwd, shell: true, env: mergedEnv()});
            // Haxe 3 printed the version to stderr, 4 to stdout.
            final outputs = [Std.string(result.stderr), Std.string(result.stdout)];
            final re = ~/([0-9]+)\.([0-9]+)\.([0-9]+)/;
            for (text in outputs) {
                if (text != null && re.match(text)) {
                    return {
                        major: Std.parseInt(re.matched(1)),
                        minor: Std.parseInt(re.matched(2)),
                        patch: Std.parseInt(re.matched(3))
                    };
                }
            }
        }
        catch (_:Any) {}
        return null;

    }

    function spawnProcess():Void {

        final args = config.serverArguments.concat(["--wait", "stdio"]);
        onLog('Starting: ${config.haxePath} ${args.join(" ")}  (cwd ${config.cwd})');

        // `shell: true` because vshaxe hands us an already shell-escaped path.
        child = ChildProcess.spawn(config.haxePath, args, cast {
            cwd: config.cwd,
            env: mergedEnv(),
            shell: true
        });
        startedAt = Date.now().getTime();
        buffer.clear();

        // Responses arrive on stderr; stdout carries compiler log output.
        child.stderr.on("data", (chunk:Buffer) -> onStderr(chunk));
        child.stdout.on("data", (chunk:Buffer) -> traceVerbose(Std.string(chunk)));
        child.on("exit", (code, signal) -> onExit(code, signal));
        child.on("error", (e) -> onLog('Haxe process error: $e'));

    }

    function mergedEnv():DynamicAccess<String> {

        final env:DynamicAccess<String> = cast js.lib.Object.assign({}, cast js.Node.process.env);
        if (config.env != null) for (key => value in config.env) env.set(key, value);
        // Lets the compiler know it is serving completion rather than building.
        env.set("HAXE_COMPLETION_SERVER", "1");
        return env;

    }

    public function updateConfig(next:HaxeDisplayServerConfig):Void {

        final changed = config.haxePath != next.haxePath
            || config.cwd != next.cwd
            || config.serverArguments.join(" ") != next.serverArguments.join(" ")
            // Haxe keys its compilation context on the argument list, so a
            // different one is a different context: the cache would not carry
            // over and restarting is the honest thing to do.
            || config.displayArguments.join(" ") != next.displayArguments.join(" ");

        config = next;
        if (changed && startPromise != null) restart("configuration changed");

    }

    public function restart(reason:String):Promise<Dynamic> {

        onLog('Restarting Haxe completion server: $reason');
        stop();
        return ensureStarted();

    }

    public function stop():Void {

        clearTimer(inactivityTimer);
        inactivityTimer = null;
        clearTimer(idleTimer);
        idleTimer = null;

        failAll("Haxe completion server stopped");

        startPromise = null;
        warmPromise = null;

        if (child != null) {
            final process = child;
            child = null;
            try {
                process.removeAllListeners();
                final pid = process.pid;
                process.kill("SIGTERM");
                js.Node.setTimeout(() -> {
                    try {
                        if (js.Node.process.platform == "win32") {
                            // `shell: true` means kill() only reaches the shell.
                            ChildProcess.spawnSync("taskkill", ["/pid", Std.string(pid), "/T", "/F"], cast {});
                        }
                        else process.kill("SIGKILL");
                    }
                    catch (_:Any) {}
                }, 2000);
            }
            catch (_:Any) {}
        }

        if (!disposed) setState(Stopped);

    }

    public function dispose():Void {

        disposed = true;
        stop();

    }

    function onExit(code:Dynamic, signal:Dynamic):Void {

        if (disposed || child == null) return;

        child = null;
        final tail = lastErrorOutput != "" ? lastErrorOutput : buffer.drain();
        failAll('Haxe completion server exited (code $code, signal $signal)');
        startPromise = null;
        warmPromise = null;

        // A bad compiler argument will fail identically forever; say so once
        // and name the setting to fix rather than looping.
        if (~/unknown option/.match(tail)) {
            final message = 'Invalid compiler argument. Check `wisdom.displayArguments` or `haxe.configurations`.\n' + tail.trim();
            onLog(message);
            setState(Failed(message));
            return;
        }

        if (Date.now().getTime() - startedAt > HEALTHY_UPTIME_MS) crashes = 0;
        crashes++;

        if (crashes >= MAX_CRASHES) {
            final message = 'Haxe completion server crashed $crashes times, giving up.\n' + tail.trim();
            onLog(message);
            setState(Failed(message));
            return;
        }

        final delay = Std.int(Math.min(30000, 500 * Math.pow(2, crashes - 1)));
        onLog('Haxe completion server exited; restarting in ${delay}ms (attempt $crashes)');
        setState(Stopped);
        js.Node.setTimeout(() -> if (!disposed) ensureStarted(), delay);

    }

    /// Requests

    /**
     * Send a display method.
     *
     * `withProject` false omits the project arguments, which is what the
     * handshake methods want.
     */
    public function callMethod<TResult>(method:String, params:Dynamic, ?options:{
        ?token:CancellationToken,
        ?coalesceKey:String,
        ?timeoutMs:Int,
        ?withProject:Bool
    }):Promise<TResult> {

        if (options == null) options = {};
        final withProject = options.withProject != false;
        final token = options.token;
        final coalesceKey = options.coalesceKey;
        final timeoutMs = options.timeoutMs != null ? options.timeoutMs : requestTimeout();

        return new Promise((resolve, reject) -> {

            final id = nextId++;
            final request = new DisplayRequest(
                id, method,
                buildArgs(id, method, params, withProject),
                coalesceKey, timeoutMs,
                cast resolve, reject
            );

            // At most one pending request per key: a keystroke makes the
            // previous, now stale, completion pointless.
            if (coalesceKey != null) {
                var n = queue.length;
                while (n-- > 0) {
                    if (queue[n].coalesceKey == coalesceKey) {
                        queue[n].resolve(null);
                        queue.splice(n, 1);
                    }
                }
            }

            if (token != null) {
                token.onCancel(() -> {
                    request.cancelled = true;
                    final at = queue.indexOf(request);
                    if (at != -1) {
                        queue.splice(at, 1);
                        request.resolve(null);
                    }
                });
            }

            queue.push(request);
            checkQueue();
        });

    }

    /** Send a raw argument list, with no `--display` and no project prefix. */
    public function callRaw(label:String, args:Array<String>, ?timeoutMs:Int):Promise<Dynamic> {

        final effectiveTimeout = timeoutMs != null ? timeoutMs : requestTimeout();

        return new Promise((resolve, reject) -> {
            final request = new DisplayRequest(-1, label, ["--cwd", config.cwd].concat(args),
                null, effectiveTimeout, cast resolve, reject);
            request.raw = true;
            queue.push(request);
            checkQueue();
        });

    }

    function buildArgs(id:Int, method:String, params:Dynamic, withProject:Bool):Array<String> {

        final request = {jsonrpc: "2.0", id: id, method: method, params: params};

        var args = ["--cwd", config.cwd];
        if (withProject) {
            args = args.concat(["--no-output", "-D", "display-details"]);
            // See the class documentation: this one is not optional.
            args = args.concat(["-D", "completion"]);
            args = args.concat(config.displayArguments);
        }
        args.push("--display");
        args.push(Json.stringify(request));
        return args;

    }

    function checkQueue():Void {

        if (current != null || child == null || queue.length == 0) return;

        current = queue.shift();
        armInactivityTimer(current.timeoutMs);
        traceVerbose('-> ${current.method}');

        try child.stdin.write(frame(current.args))
        catch (e:Any) {
            final request = current;
            current = null;
            request.reject('Could not write to Haxe: $e');
            checkQueue();
        }

    }

    /**
     * `int32` LE length, excluding the header, then each argument plus a newline.
     */
    function frame(args:Array<String>):Buffer {

        final parts = [for (arg in args) Buffer.from(arg + "\n")];
        var length = 0;
        for (part in parts) length += part.length;

        final header = Buffer.alloc(4);
        header.writeInt32LE(length, 0);
        return Buffer.concat([header].concat(parts));

    }

    function onStderr(chunk:Buffer):Void {

        // Any byte at all means the compiler is alive and working.
        if (current != null) armInactivityTimer(current.timeoutMs);

        buffer.append(chunk);
        while (true) {
            final payload = buffer.tryRead();
            if (payload == null) break;
            handlePayload(payload);
        }

    }

    function handlePayload(payload:String):Void {

        clearTimer(inactivityTimer);
        inactivityTimer = null;

        final request = current;
        current = null;
        armIdleTimer();

        var hasError = false;
        final lines = [];
        for (line in payload.split("\n")) {
            final marker = line.length > 0 ? line.charCodeAt(0) : -1;
            if (marker == LOG_LINE) {
                // A log line, with embedded newlines encoded as the same marker.
                traceVerbose(line.substr(1).split(String.fromCharCode(LOG_LINE)).join("\n"));
                continue;
            }
            if (marker == ERROR_LINE) {
                hasError = true;
                continue;
            }
            lines.push(line);
        }
        final body = lines.join("\n").trim();

        if (request == null) {
            traceVerbose('Unsolicited payload from Haxe: ${body.substr(0, 200)}');
            checkQueue();
            return;
        }

        if (request.cancelled) {
            checkQueue();
            return;
        }

        if (request.raw) {
            if (hasError) {
                lastErrorOutput = body;
                request.reject(body);
            }
            else request.resolve(body);
            checkQueue();
            return;
        }

        if (hasError) {
            lastErrorOutput = body;
            request.reject(body);
            checkQueue();
            return;
        }

        try {
            final message:Dynamic = Json.parse(body);

            // The compiler answers one request at a time, so the id is
            // redundant -- which is exactly why a mismatch means the stream has
            // desynced, and is worth catching here instead of as a wrong answer.
            if (message.id != null && request.id != -1 && message.id != request.id) {
                onLog('Haxe response id ${message.id} does not match request ${request.id}');
                request.reject("response out of sync");
                restart("response id mismatch");
                return;
            }

            if (message.error != null) {
                final data:Array<Dynamic> = message.error.data;
                final detail = data != null && data.length > 0
                    ? [for (entry in data) Std.string(entry.message)].join(" | ")
                    : Std.string(message.error.message);
                request.reject(detail);
            }
            else {
                // Results are wrapped twice: {result: {result: T, timestamp}}.
                request.resolve(message.result != null ? message.result.result : null);
            }
        }
        catch (e:Any) {
            request.reject('Could not parse Haxe response: $e');
        }

        checkQueue();

    }

    function failAll(reason:String):Void {

        final pending = queue;
        queue = [];
        final inFlight = current;
        current = null;

        if (inFlight != null) inFlight.reject(reason);
        for (request in pending) request.reject(reason);

    }

    /// Convenience wrappers
    //
    // Every one of these carries a rewritten `contents`, so every one of them
    // invalidates first. Without that the compiler may answer from a module it
    // typed under different contents, and the result then depends on what was
    // asked before -- hover returning the enclosing literal, definition coming
    // back empty. Keeping the invalidate here makes it impossible to forget.

    public function completion(file:String, contents:String, offset:Int, wasAutoTriggered:Bool, ?token:CancellationToken):Promise<CompletionResult> {

        return withFreshModule(file, () -> callMethod(DisplayMethods.Completion, ({
            file: file,
            contents: contents,
            offset: offset,
            wasAutoTriggered: wasAutoTriggered,
            meta: [":deprecated"]
        } : CompletionParams), {token: token, coalesceKey: 'completion:$file'}));

    }

    public function hover(file:String, contents:String, offset:Int, ?token:CancellationToken):Promise<HoverResult> {

        return withFreshModule(file, () -> callMethod(DisplayMethods.Hover,
            ({file: file, contents: contents, offset: offset} : PositionParams),
            {token: token, coalesceKey: 'hover:$file'}));

    }

    public function definition(file:String, contents:String, offset:Int, ?token:CancellationToken):Promise<Array<DisplayLocation>> {

        return withFreshModule(file, () -> callMethod(DisplayMethods.Definition,
            ({file: file, contents: contents, offset: offset} : PositionParams),
            {token: token, coalesceKey: 'definition:$file'}));

    }

    public function completionItemResolve(index:Int, ?token:CancellationToken):Promise<Dynamic> {

        return callMethod(DisplayMethods.CompletionItemResolve, {index: index}, {token: token});

    }

    public function invalidate(file:String):Void {

        if (child == null) return;
        callMethod(DisplayMethods.ServerInvalidate, {file: file}).catchError(_ -> null);

    }

    public function moduleCreated(file:String):Void {

        if (child == null) return;
        callMethod(DisplayMethods.ServerModuleCreated, {file: file}).catchError(_ -> null);

    }

    function withFreshModule<T>(file:String, send:() -> Promise<T>):Promise<T> {

        return callMethod(DisplayMethods.ServerInvalidate, {file: file})
            .then(_ -> send(), _ -> send());

    }

    /// Timers

    inline function requestTimeout():Int {
        return config.requestTimeoutMs != null ? config.requestTimeoutMs : DEFAULT_REQUEST_TIMEOUT_MS;
    }

    function armInactivityTimer(timeoutMs:Int):Void {

        clearTimer(inactivityTimer);
        inactivityTimer = js.Node.setTimeout(() -> {
            // There is no way to abort a `--display` call, and a late answer
            // would be matched to the next request, so restarting is the only
            // safe recovery.
            onLog('Haxe request timed out after ${timeoutMs}ms');
            restart("request timeout");
        }, timeoutMs);

    }

    function armIdleTimer():Void {

        clearTimer(idleTimer);
        idleTimer = null;

        final idleMs = config.idleShutdownMs != null ? config.idleShutdownMs : 0;
        if (idleMs <= 0) return;

        idleTimer = js.Node.setTimeout(() -> {
            if (queue.length == 0 && current == null) {
                onLog("Haxe completion server idle, shutting down");
                stop();
            }
        }, idleMs);

    }

    inline function clearTimer(timer:Dynamic):Void {
        if (timer != null) js.Node.clearTimeout(timer);
    }

    /// Reporting

    function setState(next:HaxeServerState):Void {

        state = next;
        onStateChange(next);

    }

    inline function traceVerbose(message:String):Void {
        onLog(message);
    }

}

/** One queued request. */
private class DisplayRequest {

    public final id:Int;
    public final method:String;
    public final args:Array<String>;
    public final coalesceKey:Null<String>;
    public final timeoutMs:Int;
    public var raw:Bool = false;
    public var cancelled:Bool = false;

    public final resolve:(result:Dynamic) -> Void;
    public final reject:(error:Dynamic) -> Void;

    public function new(id:Int, method:String, args:Array<String>, coalesceKey:Null<String>,
                        timeoutMs:Int, resolve:(result:Dynamic) -> Void, reject:(error:Dynamic) -> Void) {
        this.id = id;
        this.method = method;
        this.args = args;
        this.coalesceKey = coalesceKey;
        this.timeoutMs = timeoutMs;
        this.resolve = resolve;
        this.reject = reject;
    }

}
