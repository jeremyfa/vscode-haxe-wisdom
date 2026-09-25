package;

import js.Node;
import wisdom.haxe.HaxeDisplayBackend;
import wisdom.lsp.CancellationToken;
import wisdom.lsp.Server;
import wisdom.lsp.WisdomProtocol;

// Initialize node require
@:jsRequire("module") extern class Module {
    static function createRequire(path:String):Dynamic;
}

/**
 * The slice of `vscode-languageserver`'s Connection we actually use.
 *
 * Request handlers are given `(params, token)` by the library; the extra
 * progress arguments it also passes are simply not declared here.
 */
typedef Connection = {
    function listen():Void;
    function onInitialize(handler:(params:Dynamic)->Dynamic):Void;
    function onInitialized(handler:(params:Dynamic)->Void):Void;
    function onDidOpenTextDocument(handler:(params:Dynamic)->Void):Void;
    function onDidChangeTextDocument(handler:(params:Dynamic)->Void):Void;
    function onDidSaveTextDocument(handler:(params:Dynamic)->Void):Void;
    function onDidCloseTextDocument(handler:(params:Dynamic)->Void):Void;
    function onDidChangeWatchedFiles(handler:(params:Dynamic)->Void):Void;
    function onCompletion(handler:(params:Dynamic, token:LibCancellationToken)->Dynamic):Void;
    function onCompletionResolve(handler:(item:Dynamic, token:LibCancellationToken)->Dynamic):Void;
    function onHover(handler:(params:Dynamic, token:LibCancellationToken)->Dynamic):Void;
    function onDefinition(handler:(params:Dynamic, token:LibCancellationToken)->Dynamic):Void;
    function onRequest(method:String, handler:(params:Dynamic, token:LibCancellationToken)->Dynamic):Void;
    function onNotification(method:String, handler:(params:Dynamic)->Void):Void;
    function sendNotification(method:String, ?params:Dynamic):Void;
    function onExit(handler:()->Void):Void;
    function onShutdown(handler:()->Void):Void;
    function sendDiagnostics(params:Dynamic):Void;
    var console:Logger;
}

/**
 * `vscode-languageserver`'s cancellation token, which it derives from
 * `$/cancelRequest` for us.
 */
typedef LibCancellationToken = {
    var isCancellationRequested:Bool;
    function onCancellationRequested(listener:(e:Dynamic)->Void):Dynamic;
}

// Logger interface
typedef Logger = {
    function log(message:String):Void;
    function info(message:String):Void;
    function warn(message:String):Void;
    function error(message:String):Void;
}

class WisdomServer {

    static final server = new Server();
    static var nextRequestId = 1;
    static var logger:Logger;

    static function main() {
        trace("INITIALIZE WISDOM SERVER");

        try {
            // Setup require for the current file's directory
            final require = Module.createRequire(Node.__filename);

            // Create LSP connection
            final connection:Connection = require('vscode-languageserver/node').createConnection();

            // Get logger
            logger = connection.console;
            logger.info('Wisdom Language Server starting...');

            // Bind logger to server implementation
            server.onLog = (message:Any, ?pos:haxe.PosInfos) -> {
                logger.log(Std.string(message));
            };

            haxe.Log.trace = server.onLog;

            // The Haxe compiler side. Constructing it starts nothing: the
            // process only appears once a request lands inside Wisdom markup.
            final backend = new HaxeDisplayBackend();
            backend.onLog = message -> logger.log(message);
            backend.onStatus = status -> connection.sendNotification(WisdomMethods.HaxeServerStatus, status);
            server.haxeBackend = backend;

            // Listen to notifications sent back to client
            server.onNotification = message -> {
                // If response is a publishDiagnostics notification, send it through connection
                if (message.method == "textDocument/publishDiagnostics") {
                    connection.sendDiagnostics(message.params);
                }
                else {
                    connection.sendNotification(message.method, message.params);
                }
            };

            /// Lifecycle

            connection.onInitialize(params -> {
                try {
                    final response = server.handleMessage(makeRequest('initialize', params));
                    if (response.error != null) throw response.error.message;
                    return response.result;
                }
                catch (e:Dynamic) {
                    logger.error('Error in onInitialize: ${e}');
                    throw e;
                }
            });

            connection.onInitialized(params -> notify('initialized', params));

            /// Document synchronization

            connection.onDidOpenTextDocument(params -> notify('textDocument/didOpen', params));
            connection.onDidChangeTextDocument(params -> notify('textDocument/didChange', params));
            connection.onDidSaveTextDocument(params -> notify('textDocument/didSave', params));
            connection.onDidCloseTextDocument(params -> notify('textDocument/didClose', params));

            /// Configuration pushed by the extension

            connection.onDidChangeWatchedFiles(params -> notify('workspace/didChangeWatchedFiles', params));

            connection.onNotification(WisdomMethods.DidChangeHaxeConfiguration,
                params -> notify(WisdomMethods.DidChangeHaxeConfiguration, params));
            connection.onNotification(WisdomMethods.RestartHaxeServer,
                params -> notify(WisdomMethods.RestartHaxeServer, params));

            /// Language features

            connection.onCompletion((params, token) -> request('textDocument/completion', params, token));
            connection.onCompletionResolve((item, token) -> request('completionItem/resolve', item, token));
            connection.onHover((params, token) -> request('textDocument/hover', params, token));
            connection.onDefinition((params, token) -> request('textDocument/definition', params, token));

            /// Shutdown

            connection.onShutdown(() -> {
                logger.info('Server shutting down...');
                backend.dispose();
            });

            connection.onExit(() -> {
                logger.info('Server exiting...');
                backend.dispose();
                Node.process.exit(0);
            });

            // Start listening
            logger.info('Server starting...');
            connection.listen();
        }
        catch (e:Dynamic) {
            trace('Fatal server error: ${e}');
            if (e != null && e.stack != null) {
                trace(e.stack);
            }
            Node.process.exit(1);
        }
    }

    /**
     * Run a request through the server and surface its answer as a promise.
     */
    static function request(method:String, params:Dynamic, token:LibCancellationToken):js.lib.Promise<Dynamic> {

        return new js.lib.Promise((resolve, reject) -> {
            try {
                server.handleRequestMessage(makeRequest(method, params), adaptToken(token), response -> {
                    if (response.error != null) {
                        logger.error('Error in ${method}: ${response.error.message}');
                        // An error here would surface as a toast in the editor. Nothing we
                        // answer is essential -- vshaxe still replies to the same request --
                        // so degrade to "no result" instead.
                        resolve(null);
                    }
                    else {
                        resolve(response.result);
                    }
                });
            }
            catch (e:Dynamic) {
                logger.error('Error in ${method}: ${e}');
                resolve(null);
            }
        });

    }

    static function notify(method:String, params:Dynamic):Void {

        try {
            server.handleNotificationMessage(makeNotification(method, params));
        }
        catch (e:Dynamic) {
            logger.error('Error in ${method}: ${e}');
        }

    }

    /**
     * Bridge the library's cancellation token to our transport-neutral one.
     */
    static function adaptToken(token:LibCancellationToken):CancellationToken {

        if (token == null) return CancellationToken.NONE;

        final adapted = new CancellationToken();
        if (token.isCancellationRequested) {
            adapted.cancel();
        }
        else {
            token.onCancellationRequested(_ -> adapted.cancel());
        }
        return adapted;

    }

    static function makeRequest(method:String, params:Dynamic):Dynamic {
        return {
            jsonrpc: "2.0",
            id: nextRequestId++,
            method: method,
            params: params
        };
    }

    static function makeNotification(method:String, params:Dynamic):Dynamic {
        return {
            jsonrpc: "2.0",
            method: method,
            params: params
        };
    }

}
