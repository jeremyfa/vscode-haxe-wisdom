package;

import js.Node;
import js.node.Path;
import tracker.Model;
import vscode.ExtensionContext;
import vscode.OutputChannel;
import vscode.StatusBarItem;
import wisdom.lsp.WisdomProtocol;

using StringTools;

// Initialize node require
@:jsRequire("module") extern class Module {
    static function createRequire(path:String):Dynamic;
}

// VSCode LSP Client externs
@:jsRequire("vscode-languageclient/node", "LanguageClient")
extern class LanguageClient {
    function new(id:String, name:String, serverOptions:Dynamic, clientOptions:Dynamic);
    function start():js.lib.Promise<Dynamic>;
    function stop():js.lib.Promise<Dynamic>;
    function dispose():Void;
    function onDidChangeState(handler:Dynamic->Void):Void;
    function sendNotification(method:String, ?params:Dynamic):Void;
    function onNotification(method:String, handler:Dynamic->Void):Void;
}

class VscodeWisdom extends Model {

    /// Exposed

    static var instance:VscodeWisdom = null;

    @:expose("activate")
    static function activate(context:ExtensionContext) {
        instance = new VscodeWisdom(context);
        return instance.activationPromise;
    }

    @:expose("deactivate")
    static function deactivate() {
        if (instance != null) {
            instance.dispose();
            instance = null;
        }
    }

    /// Properties

    var context:ExtensionContext;
    var lspClient:LanguageClient;
    var lspOutputChannel:OutputChannel;
    var activationPromise:js.lib.Promise<Dynamic>;
    var disposed:Bool = false;

    var resolver:HaxeDisplayArgumentsResolver;
    var tailwind:TailwindIntegration;
    var statusItem:StatusBarItem;
    var configGeneration:Int = 0;
    var pendingRefresh:Dynamic = null;
    var clientReady:Bool = false;

    /// Lifecycle

    function new(context:ExtensionContext) {
        super();
        this.context = context;

        // Created but deliberately not shown: this extension activates on any
        // Haxe project, and stealing the panel on startup is not ours to do.
        // `Wisdom: Show Output Channel` opens it on demand.
        lspOutputChannel = Vscode.window.createOutputChannel("Wisdom");
        lspOutputChannel.appendLine("Initializing Wisdom Language Client...");

        registerFoldingProvider();
        registerCommands();
        setupConfiguration();

        activationPromise = createClient();
    }

    function registerFoldingProvider() {
        final provider = new WisdomFoldingProvider();

        // Create provider object compatible with FoldingRangeProvider interface
        final foldingProvider:vscode.FoldingRangeProvider = {
            provideFoldingRanges: provider.provideFoldingRanges,
            onDidChangeFoldingRanges: null
        };

        final disposable = Vscode.languages.registerFoldingRangeProvider(
            {language: "haxe"},
            foldingProvider
        );

        context.subscriptions.push(disposable);
    }

    function registerCommands() {

        inline function register(id:String, handler:Void->Void) {
            context.subscriptions.push(cast Vscode.commands.registerCommand(id, handler));
        }

        register("wisdom.showOutput", () -> lspOutputChannel.show(true));

        register("wisdom.restartHaxeServer", () -> {
            if (lspClient != null && clientReady) {
                lspClient.sendNotification(WisdomMethods.RestartHaxeServer, {});
                log("Restarting the Haxe completion server...");
            }
        });

        register("wisdom.selectConfiguration", () -> selectConfiguration());

        register("wisdom.configureTailwind", () -> if (tailwind != null) tailwind.configureCommand());

    }

    /// Haxe configuration

    function setupConfiguration() {

        resolver = new HaxeDisplayArgumentsResolver(context, getVshaxe(), log);
        resolver.refresh();

        if (resolver.current != null) {
            log('Haxe configuration: ${resolver.current.label} (${resolver.current.source})');
        }
        final html = resolver.htmlBackend(resolver.workspaceRoot());
        log('HTML backend: ${html.enabled ? "on" : "off"} (${html.source})');

        tailwind = new TailwindIntegration(context, resolver, log);
        final tw = tailwind.isActive();
        log('Tailwind: ${tw.active ? "on" : "off"} (${tw.source})');

        statusItem = Vscode.window.createStatusBarItem(cast 1, 0);
        statusItem.command = "wisdom.showOutput";
        context.subscriptions.push(cast statusItem);

        // Anything that can change which arguments the compiler should run with.
        context.subscriptions.push(cast Vscode.workspace.onDidChangeConfiguration(event -> {
            // Our own settings change what the server does without changing the
            // compiler arguments, so they have to be pushed even when the
            // arguments compare equal.
            if (event.affectsConfiguration("wisdom")) scheduleRefresh(true);
            else if (event.affectsConfiguration("haxe")) scheduleRefresh();
        }));

        // A `files` glob may select a different configuration per file.
        context.subscriptions.push(cast Vscode.window.onDidChangeActiveTextEditor(_ -> scheduleRefresh()));

        // The set of HXML files at the root, and the contents of the one we use.
        final watcher = Vscode.workspace.createFileSystemWatcher("**/*.hxml");
        watcher.onDidCreate(_ -> scheduleRefresh());
        watcher.onDidDelete(_ -> scheduleRefresh());
        // The arguments are unchanged but what they mean is not, so force a push.
        watcher.onDidChange(_ -> scheduleRefresh(true));
        context.subscriptions.push(cast watcher);

    }

    /**
     * Coalesce bursts of change events into a single push.
     *
     * Saving an HXML file can fire several watchers at once, and every push
     * that changes the arguments restarts the compiler.
     */
    function scheduleRefresh(force:Bool = false) {

        if (pendingRefresh != null) Node.clearTimeout(pendingRefresh);
        pendingRefresh = Node.setTimeout(() -> {
            pendingRefresh = null;
            final changed = resolver.refresh();
            if (changed || force) pushConfiguration();
        }, 750);

    }

    function pushConfiguration() {

        if (lspClient == null || !clientReady) return;

        configGeneration++;
        final configuration = resolver.configuration(configGeneration);
        lspClient.sendNotification(WisdomMethods.DidChangeHaxeConfiguration, configuration);

        if (configuration.displayArguments != null) {
            log('Haxe configuration: ${configuration.source} [${configuration.displayArguments.join(" ")}]');
        }
        else {
            log("Haxe configuration: none (typed features disabled)");
        }
        log('HTML backend: ${configuration.htmlBackend ? "on" : "off"} (${configuration.htmlBackendSource})');

        // A project that just gained `-D wisdom_tailwind` may need the Tailwind
        // extension pointed at its markup.
        if (tailwind != null) tailwind.check();

    }

    function selectConfiguration() {

        final candidates = resolver.candidates;
        if (candidates.length == 0) {
            Vscode.window.showInformationMessage(
                "Wisdom: no Haxe configuration found. Set `wisdom.displayArguments`, or add an HXML file at the workspace root."
            );
            return;
        }

        final picks:Array<Dynamic> = [for (candidate in candidates) {
            label: candidate.label,
            description: candidate.source
        }];

        Vscode.window.showQuickPick(cast picks, cast {placeHolder: "Haxe configuration for Wisdom completion"})
            .then(choice -> {
                if (choice != null) {
                    for (index in 0...picks.length) {
                        if (picks[index] == choice) {
                            resolver.selectIndex(index);
                            pushConfiguration();
                            break;
                        }
                    }
                }
                return choice;
            });

    }

    function getVshaxe():Null<Vshaxe> {

        final extension = Vscode.extensions.getExtension("nadako.vshaxe");
        if (extension == null) {
            log("vshaxe is not installed; reading `haxe.executable` directly instead.");
            return null;
        }
        // `exports` is only populated once the extension has activated, and we
        // may well be running before it does. Falling back is harmless: the
        // executable is then read from settings the same way vshaxe would.
        if (!extension.isActive) {
            extension.activate();
            return null;
        }
        return extension.exports;

    }

    /// Status

    function onHaxeServerStatus(status:HaxeServerStatus) {

        if (statusItem == null) return;

        switch status.state {
            case "starting" | "warming":
                statusItem.text = "$(sync~spin) Wisdom";
                statusItem.tooltip = "Preparing Haxe completion for Wisdom markup...";
                statusItem.show();
            case "failed":
                statusItem.text = "$(warning) Wisdom";
                statusItem.tooltip = status.message != null ? status.message : "Haxe completion unavailable";
                statusItem.show();
                if (status.message != null) log(status.message);
            case _:
                statusItem.hide();
        }

    }

    /// Client

    function createClient():js.lib.Promise<Dynamic> {
        return new js.lib.Promise(function(resolve:Dynamic->Void, reject:Dynamic->Void):Void {
            try {
                // Setup require for the current file's directory
                final require = Module.createRequire(Node.__filename);

                // Get server module path
                final serverModule = Path.join(context.extensionPath, 'wisdom-server.js');

                // Setup server options
                final serverOptions = {
                    run: {
                        module: serverModule,
                        transport: require('vscode-languageclient/node').TransportKind.ipc,
                        options: {
                            cwd: context.extensionPath
                        }
                    },
                    debug: {
                        module: serverModule,
                        transport: require('vscode-languageclient/node').TransportKind.ipc,
                        options: {
                            execArgv: ["--nolazy", "--inspect=6009"],
                            cwd: context.extensionPath
                        }
                    }
                };

                configGeneration++;

                // Setup client options
                final clientOptions = {
                    documentSelector: [{
                        scheme: "file",
                        language: "haxe"
                    }],
                    synchronize: {
                        fileEvents: Vscode.workspace.createFileSystemWatcher("**/*.hx")
                    },
                    outputChannel: lspOutputChannel,
                    // The server can read neither VSCode settings nor vshaxe, so
                    // the resolved configuration travels with the handshake.
                    initializationOptions: {
                        haxeConfiguration: resolver.configuration(configGeneration)
                    },
                    errorHandler: {
                        error: function(error:Dynamic, message:String, count:Int):Dynamic {
                            log('Error: ${message} (${error})');
                            return require('vscode-languageclient').ErrorAction.Continue;
                        },
                        closed: function():Dynamic {
                            log('Connection closed');
                            return require('vscode-languageclient').CloseAction.DoNotRestart;
                        }
                    }
                };

                // Create client
                lspClient = new LanguageClient(
                    "wisdom-language-server",
                    "Wisdom Language Server",
                    serverOptions,
                    clientOptions
                );

                // Start the client
                context.subscriptions.push(cast lspClient);
                lspClient.start().then(function(value:Dynamic) {
                    clientReady = true;
                    lspClient.onNotification(WisdomMethods.HaxeServerStatus, status -> onHaxeServerStatus(status));
                    resolver.warnIfUnresolved();
                    if (tailwind != null) tailwind.check();
                    resolve(value);
                    return value;
                }, function(error:Dynamic) {
                    log('Failed to start client: ${error}');
                    reject(error);
                    return error;
                });
            }
            catch (e:Dynamic) {
                log('Error creating client: ${e}');
                reject(e);
            }
        });
    }

    inline function log(message:String) {
        if (lspOutputChannel != null) lspOutputChannel.appendLine(message);
    }

    function dispose() {
        if (!disposed) {
            disposed = true;

            if (pendingRefresh != null) {
                Node.clearTimeout(pendingRefresh);
                pendingRefresh = null;
            }

            if (lspClient != null) {
                lspClient.stop().then(function(value:Dynamic) {
                    if (lspOutputChannel != null) {
                        lspOutputChannel.dispose();
                        lspOutputChannel = null;
                    }
                    lspClient.dispose();
                    lspClient = null;
                    return value;
                });
            } else if (lspOutputChannel != null) {
                lspOutputChannel.dispose();
                lspOutputChannel = null;
            }
        }
    }

}
