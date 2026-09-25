package wisdom.lsp;

import wisdom.lsp.Callback;
import wisdom.lsp.Protocol;
import wisdom.lsp.WisdomProtocol;
import wisdom.lsp.features.LocalCompletions;
import wisdom.lsp.features.TypedFeatures;
import wisdom.lsp.features.WebData;
import wisdom.lsp.features.WisdomDocs;
import wisdom.lsp.markup.MarkupScanner;
import wisdom.lsp.markup.MarkupTypes;

using StringTools;

/**
 * Main LSP server implementation for Wisdom.
 *
 * Transport-agnostic on purpose: `WisdomServer` owns the Node / JSON-RPC side
 * and feeds synthetic messages in here. Requests are asynchronous (every typed
 * feature ends up waiting on the Haxe display server), notifications stay
 * synchronous because their ordering is what keeps the document store correct.
 */
class Server {

    // Synced documents, by URI
    final documents:Map<String, TextDocument> = [];

    // Scan results, invalidated by document version. Full sync hands us the
    // whole text on every keystroke, and re-scanning a 50 KB file is well under
    // a millisecond, so there is nothing to gain from an incremental parse.
    final scans:Map<String, {version:Int, result:ScanResult}> = [];

    // Client capabilities from the initialize request
    var clientCapabilities:ClientCapabilities;

    /**
     * The Haxe compiler, when there is one.
     *
     * Injected by the transport layer rather than constructed here: the real
     * implementation is Node-only, and a null backend is the honest shape of
     * "no Haxe configuration", which is a state we genuinely run in.
     */
    public var haxeBackend(default, set):Null<HaxeBackend> = null;

    function set_haxeBackend(backend:Null<HaxeBackend>):Null<HaxeBackend> {
        haxeBackend = backend;
        typed = backend != null ? new TypedFeatures(backend) : null;
        return backend;
    }

    var typed:Null<TypedFeatures> = null;

    var haxeConfiguration:Null<HaxeDisplayConfiguration> = null;

    // Track server state
    var initialized:Bool = false;
    var shutdown:Bool = false;

    public dynamic function onLog(message:Any, ?pos:haxe.PosInfos) {
        #if (js && hxnodejs)
        js.Node.console.log(message);
        #end
    }

    public dynamic function onNotification(message:NotificationMessage) {
        // Needs to be replaced by proper handler
    }

    public function new() {}

    /**
     * Handle an incoming request.
     *
     * `respond` is called exactly once, possibly long after this returns.
     */
    public function handleRequestMessage(request:RequestMessage, token:CancellationToken, respond:Resolve<ResponseMessage>):Void {

        if (token == null) token = CancellationToken.NONE;

        var responded = false;
        inline function settle(response:ResponseMessage) {
            if (responded) return;
            responded = true;
            respond(response);
        }

        final resolve:Resolve<Any> = result -> settle(createResponse(request.id, result));
        final reject:Reject = error -> settle(createErrorResponse(request.id, error.code, error.message, error.data));

        try {
            if (!initialized && request.method != "initialize") {
                throw { code: ErrorCodes.ServerNotInitialized, message: "Server not initialized" };
            }

            switch (request.method) {
                case "initialize":
                    resolve(handleInitialize(cast request.params));

                case "shutdown":
                    resolve(handleShutdown());

                case "textDocument/completion":
                    handleCompletion(cast request.params, token, cast resolve, reject);

                case "completionItem/resolve":
                    handleCompletionResolve(cast request.params, token, cast resolve, reject);

                case "textDocument/hover":
                    handleHover(cast request.params, token, cast resolve, reject);

                case "textDocument/definition":
                    handleDefinition(cast request.params, token, cast resolve, reject);

                case _:
                    throw { code: ErrorCodes.MethodNotFound, message: 'Method not found: ${request.method}' };
            }
        }
        catch (e:Any) {
            if (Reflect.hasField(e, 'code') && Reflect.hasField(e, 'message')) {
                final err:ResponseError = e;
                settle(createErrorResponse(request.id, err.code, err.message));
            }
            else {
                settle(createErrorResponse(request.id, ErrorCodes.InternalError, Std.string(e)));
            }
        }

    }

    /**
     * Handle an incoming notification.
     */
    public function handleNotificationMessage(notification:NotificationMessage):Void {

        try {
            if (!initialized && notification.method != "initialized") return;

            switch (notification.method) {
                case "initialized":
                    initialized = true;

                case "textDocument/didOpen":
                    handleDidOpenTextDocument(cast notification.params);

                case "textDocument/didChange":
                    handleDidChangeTextDocument(cast notification.params);

                case "textDocument/didSave":
                    handleDidSaveTextDocument(cast notification.params);

                case "textDocument/didClose":
                    handleDidCloseTextDocument(cast notification.params);

                case WisdomMethods.DidChangeHaxeConfiguration:
                    handleDidChangeHaxeConfiguration(cast notification.params);

                case WisdomMethods.RestartHaxeServer:
                    if (haxeBackend != null) haxeBackend.restart();

                case "workspace/didChangeWatchedFiles":
                    handleDidChangeWatchedFiles(cast notification.params);

                case "exit":
                    handleExit();

                case _:
                    // Ignore unknown notifications
            }
        }
        catch (e:Any) {
            onLog('Error handling ${notification.method}: $e');
        }

    }

    /**
     * Dispatch a raw JSON-RPC message.
     *
     * Kept for callers that do not care about asynchrony; a request handled
     * this way only produces a response if its handler happened to answer
     * synchronously (`initialize` and `shutdown` do).
     */
    public function handleMessage(msg:Message):Null<ResponseMessage> {

        try {
            if (Reflect.hasField(msg, "method")) {
                if (Reflect.hasField(msg, "id")) {
                    var response:ResponseMessage = null;
                    handleRequestMessage(cast msg, CancellationToken.NONE, r -> response = r);
                    return response;
                }
                else {
                    handleNotificationMessage(cast msg);
                    return null;
                }
            }

            return createErrorResponse(null, ErrorCodes.InvalidRequest, "Invalid message");
        }
        catch (e:Dynamic) {
            return createErrorResponse(null, ErrorCodes.ParseError, Std.string(e));
        }

    }

    /**
     * Create error response
     */
    function createErrorResponse(id:RequestId, code:ErrorCodes, message:String, ?data:Any):ResponseMessage {
        final response:ResponseMessage = {
            jsonrpc: "2.0",
            id: id,
            error: {
                code: code,
                message: message,
                data: data
            }
        };
        return response;
    }

    /**
     * Create success response
     */
    function createResponse(id:RequestId, result:Any):ResponseMessage {
        final response:ResponseMessage = {
            jsonrpc: "2.0",
            id: id,
            result: result
        };
        return response;
    }

    /**
     * Handle initialize request
     */
    function handleInitialize(params:InitializeParams):{ capabilities: ServerCapabilities } {
        if (initialized) {
            throw { code: ErrorCodes.InvalidRequest, message: "Server already initialized" };
        }

        clientCapabilities = params.capabilities;

        final options:Dynamic = params.initializationOptions;
        if (options != null && options.haxeConfiguration != null) {
            handleDidChangeHaxeConfiguration(options.haxeConfiguration);
        }

        return {
            capabilities: {
                // Full document sync means we'll get the entire document content on changes
                textDocumentSync: {
                    openClose: true,
                    change: TextDocumentSyncKind.Full,
                    save: { // Save notification support
                        includeText: true
                    }
                },
                // `$` is deliberately absent: inside `${...}` the markup is a plain
                // interpolated string as far as the compiler is concerned, so vshaxe
                // already answers correctly there and we must not duplicate it.
                // ` ` and `.` fire all over any .hx file, which is free because the
                // gate in every handler bails on a single `hasMarkup` Bool read.
                completionProvider: {
                    resolveProvider: true,
                    // `"` opens an attribute's value list (`type="`). It fires in
                    // every Haxe string, which the `hasMarkup` gate makes free.
                    triggerCharacters: ["<", "/", ".", " ", "\""]
                },
                hoverProvider: true,
                definitionProvider: true,
                // Owned by vshaxe, we have nothing to add
                documentSymbolProvider: false,
                documentFormattingProvider: false,
                referencesProvider: false
            }
        };
    }

    /**
     * Handle shutdown request
     */
    function handleShutdown():Null<Any> {
        if (shutdown) {
            throw { code: ErrorCodes.InvalidRequest, message: "Server already shut down" };
        }
        shutdown = true;
        return null;
    }

    /**
     * Handle exit notification
     */
    function handleExit() {
        #if (sys || hxnodejs)
        Sys.exit(shutdown ? 0 : 1);
        #end
    }

    /// Configuration

    /**
     * The extension resolved a Haxe configuration for us.
     *
     * `generation` guards against an older payload overtaking a newer one; the
     * backend is told even when nothing resolved, since that is what switches
     * the typed features off.
     */
    function handleDidChangeHaxeConfiguration(config:HaxeDisplayConfiguration):Void {

        if (config == null) return;
        if (haxeConfiguration != null && config.generation < haxeConfiguration.generation) return;

        haxeConfiguration = config;
        onLog('Haxe configuration: ${config.source}'
            + (config.displayArguments != null ? ' [${config.displayArguments.join(" ")}]' : ' (typed features disabled)'));

        if (haxeBackend != null) haxeBackend.configure(config);

    }

    /// Document synchronization

    function handleDidOpenTextDocument(params:{textDocument:TextDocumentItem}) {
        final doc = params.textDocument;
        updateDocument(doc.uri, doc.text, doc.version);
    }

    function handleDidChangeTextDocument(params:{
        textDocument:VersionedTextDocumentIdentifier,
        contentChanges:Array<TextDocumentContentChangeEvent>
    }) {
        // Only correct because we announce Full sync: the last change carries
        // the whole document.
        if (params.contentChanges.length > 0) {
            final change = params.contentChanges[params.contentChanges.length - 1];
            updateDocument(params.textDocument.uri, change.text, params.textDocument.version);
        }
    }

    function handleDidSaveTextDocument(params:{
        textDocument:TextDocumentIdentifier,
        ?text:String
    }) {
        if (params.text != null) {
            final existing = documents.get(params.textDocument.uri);
            updateDocument(params.textDocument.uri, params.text, existing != null ? existing.version : 0);
        }
    }

    function handleDidCloseTextDocument(params:{textDocument:TextDocumentIdentifier}) {
        documents.remove(params.textDocument.uri);
        scans.remove(params.textDocument.uri);
    }

    /**
     * Files changed on disk.
     *
     * A new `.hx` is a module the compiler has never seen; a changed or deleted
     * one may be cached. Both are cheap notifications and neither starts a
     * server that is not already running.
     */
    function handleDidChangeWatchedFiles(params:{changes:Array<{uri:String, type:Int}>}):Void {

        if (haxeBackend == null || params == null || params.changes == null) return;

        for (change in params.changes) {
            final path = TypedFeatures.fsPath(change.uri);
            // 1 Created, 2 Changed, 3 Deleted
            if (change.type == 1) haxeBackend.fileCreated(path);
            else haxeBackend.fileChanged(path);
        }

    }

    function updateDocument(uri:String, content:String, version:Int = 0) {

        // The compiler reads other files from disk, so a module it has cached
        // for this one is now stale.
        if (haxeBackend != null) haxeBackend.fileChanged(TypedFeatures.fsPath(uri));

        final existing = documents.get(uri);
        if (existing != null) {
            existing.update(content, version);
        }
        else {
            documents.set(uri, new TextDocument(uri, content, version));
        }

    }

    /// Language features

    /**
     * Where the cursor is, or null when this request is not ours to answer.
     *
     * The order of these checks is the whole zero-cost guarantee: on a project
     * with no Wisdom markup every request stops at `hasMarkup`, which is one
     * `Bool` read. Nothing scans the workspace and, once the Haxe display
     * server exists, nothing starts it either.
     */
    function contextFor(params:TextDocumentPositionParams):Null<{doc:TextDocument, scan:ScanResult, offset:Int, context:CursorContext}> {

        final doc = documents.get(params.textDocument.uri);
        if (doc == null || !doc.hasMarkup) return null;

        final offset = doc.offsetAt(params.position);
        final scan = scanOf(doc);

        return {doc: doc, scan: scan, offset: offset, context: MarkupScanner.contextAt(scan, offset)};

    }

    /**
     * Whether HTML/SVG tags, attributes and their documentation are offered.
     *
     * Decided on the client from `wisdom.htmlBackend` and a scan of the hxml
     * chain for `-D wisdom_html`; the server only reads the answer. With no
     * configuration at all the answer is no: the backend is unknown, and
     * Wisdom's control tags and attributes do not depend on it.
     */
    inline function htmlEnabled():Bool {
        return haxeConfiguration != null && haxeConfiguration.htmlBackend;
    }

    function scanOf(doc:TextDocument):ScanResult {

        final cached = scans.get(doc.uri);
        if (cached != null && cached.version == doc.version) return cached.result;

        final result = MarkupScanner.scan(doc.content);
        scans.set(doc.uri, {version: doc.version, result: result});
        return result;

    }

    function handleCompletion(params:CompletionParams, token:CancellationToken, resolve:Resolve<Null<CompletionList>>, reject:Reject):Void {

        final at = contextFor(params);
        if (at == null) {
            resolve(null);
            return;
        }

        switch at.context {

            case InOpenTagName(region, tag, _, prefixStart, isClosing):
                final local = LocalCompletions.tagNames(
                    at.doc, region, tag, prefixStart, at.offset, isClosing,
                    MarkupScanner.tagStackAt(at.scan, at.offset), htmlEnabled()
                );
                final prefix = at.doc.content.substring(prefixStart, at.offset);

                // A closing tag can only be one of the tags already open, and a
                // lowercase prefix cannot name a component, so neither is worth
                // a round trip to the compiler.
                if (isClosing || !mayBeComponent(prefix) || typed == null || !typed.available()) {
                    resolve({isIncomplete: false, items: local});
                    return;
                }

                typed.componentNames(at.doc, region, tag, prefixStart, at.offset, token, components -> {
                    if (components == null) {
                        // The compiler is still warming up. `isIncomplete` makes
                        // the editor ask again on the next keystroke, so the
                        // components appear without the user doing anything.
                        resolve({isIncomplete: true, items: local});
                        return;
                    }
                    resolve({isIncomplete: false, items: local.concat(components)});
                });

            case InAttrName(region, tag, _, prefixStart, used):
                final local = LocalCompletions.attrNames(at.doc, tag, prefixStart, at.offset, used, htmlEnabled());

                final isComponent = switch tag.kind {
                    case Component: true;
                    case _: false;
                }
                if (!isComponent || typed == null || !typed.available()) {
                    resolve({isIncomplete: false, items: local});
                    return;
                }

                typed.componentAttributes(at.doc, region, tag, prefixStart, at.offset, used, token, props -> {
                    if (props == null) {
                        resolve({isIncomplete: true, items: local});
                        return;
                    }
                    resolve({isIncomplete: false, items: local.concat(props)});
                });

            // Inside `attr="..."` on an element: its enumerated values, if any.
            // The scanner never reports this context inside a `${}`.
            case InAttrStringValue(_, tag, attr) if (htmlEnabled() && isHtmlTag(tag)):
                resolve(LocalCompletions.attrValues(at.doc, tag, attr, at.offset));

            // OutsideMarkup, InHaxeExpr, InComment, InText, and attribute values
            // elsewhere: either not markup at all, or a position vshaxe already
            // answers correctly. Answering anything here would duplicate or,
            // worse, contradict it.
            case _:
                resolve(null);
        }

    }

    static function isHtmlTag(tag:MarkupTag):Bool {

        return switch tag.kind {
            case Html: true;
            case _: false;
        }

    }

    /** Only an uppercase or dotted prefix can name a component. */
    static function mayBeComponent(prefix:String):Bool {

        if (prefix.length == 0) return true;
        if (prefix.indexOf(".") != -1) return true;
        final first = prefix.charCodeAt(0);
        return first >= 'A'.code && first <= 'Z'.code;

    }

    function handleCompletionResolve(item:CompletionItem, token:CancellationToken, resolve:Resolve<CompletionItem>, reject:Reject):Void {

        // Elements and attributes point at the embedded documentation; filling
        // it here keeps the completion list itself small. No compiler involved.
        final data:Dynamic = item.data;
        if (data != null && data.web != null && item.documentation == null) {
            final web:Dynamic = data.web;
            final text = web.kind == "tag"
                ? WebData.tagHoverMarkdown(web.tag)
                : WebData.attributeHoverMarkdown(web.tag, web.name);
            if (text != null) item.documentation = ({kind: MarkupKind.Markdown, value: text} : MarkupContent);
        }

        // Compiler-backed items carry the index Haxe needs; the rest are done.
        if (typed == null) {
            resolve(item);
            return;
        }
        typed.resolveItem(item, token, resolve);

    }

    /**
     * Hover, for everything the markup scanner can name.
     *
     * VSCode stacks hovers from every extension and there is no way to
     * suppress vshaxe's, which for any position inside a `'<>...'` literal is
     * the unhelpful `String`. So ours is strictly additive: it answers on tag
     * names and attribute names, where it has something to say, and stays
     * silent everywhere else.
     */
    function handleHover(params:TextDocumentPositionParams, token:CancellationToken, resolve:Resolve<Null<Hover>>, reject:Reject):Void {

        if (haxeConfiguration != null && !haxeConfiguration.settings.hoverEnabled) {
            resolve(null);
            return;
        }

        final at = contextFor(params);
        if (at == null) {
            resolve(null);
            return;
        }

        switch at.context {

            // Opening or closing tag name: both should tell the same story.
            case InOpenTagName(region, tag, _, _, _):
                final range = at.doc.rangeAt(tag.nameStart, tag.nameEnd);
                switch tag.kind {
                    case Control(_):
                        resolve(markdown(WisdomDocs.tagHover(tag.name), range));
                    // Lowercase, so the scanner files it under Html; it is Wisdom's.
                    case Html if (tag.name == "portal"):
                        resolve(markdown(WisdomDocs.tagHover("portal"), range));
                    case Html if (htmlEnabled()):
                        resolve(markdown(WebData.tagHoverMarkdown(tag.name), range));
                    case Component if (typed != null && typed.available()):
                        typed.hover(at.doc, region, tag, at.offset, token, resolve);
                    case _:
                        resolve(null);
                }

            case InAttrName(region, tag, _, _, _):
                // The context is also reported from the whitespace between
                // attributes; a hover only means something on a name.
                final attr = attrAt(tag, at.offset);
                if (attr == null) {
                    resolve(null);
                    return;
                }
                final range = at.doc.rangeAt(attr.nameStart, attr.nameEnd);

                // Wisdom's own attributes mean the same on every tag, and
                // their meaning is ours to explain, not MDN's.
                final wisdom = WisdomDocs.attributeHover(attr.name, tag.name);
                if (wisdom != null) {
                    resolve(markdown(wisdom, range));
                    return;
                }

                switch tag.kind {
                    case Html if (htmlEnabled()):
                        resolve(markdown(WebData.attributeHoverMarkdown(tag.name, attr.name), range));
                    case Component if (typed != null && typed.available()):
                        typed.attributeHover(at.doc, region, tag, attr, at.offset, token, resolve);
                    case _:
                        resolve(null);
                }

            // Text, interpolations, comments, attribute values: vshaxe's
            // answer stands alone there.
            case _:
                resolve(null);
        }

    }

    /** The attribute whose name spans `offset`, if the cursor is on one. */
    static function attrAt(tag:MarkupTag, offset:Int):Null<MarkupAttr> {

        for (attr in tag.attrs) {
            if (offset >= attr.nameStart && offset <= attr.nameEnd) return attr;
        }
        return null;

    }

    /** A markdown hover, or null when there is nothing to show. */
    static function markdown(value:Null<String>, range:Range):Null<Hover> {

        if (value == null) return null;
        return {
            contents: ({kind: MarkupKind.Markdown, value: value} : MarkupContent),
            range: range
        };

    }

    function handleDefinition(params:TextDocumentPositionParams, token:CancellationToken, resolve:Resolve<Null<Array<LocationLink>>>, reject:Reject):Void {

        if (haxeConfiguration != null && !haxeConfiguration.settings.definitionEnabled) {
            resolve(null);
            return;
        }

        final at = contextFor(params);
        if (at == null || typed == null || !typed.available()) {
            resolve(null);
            return;
        }

        switch at.context {
            // Both `<Foo` and `</Foo` lead to the same declaration, which is
            // what ctrl/cmd+click on either should do.
            case InOpenTagName(region, tag, _, _, _) if (isComponentTag(tag)):
                typed.definition(at.doc, region, tag, at.offset, token, resolve);
            case _:
                resolve(null);
        }

    }

    static function isComponentTag(tag:MarkupTag):Bool {

        return switch tag.kind {
            case Component: true;
            case _: false;
        }

    }

}
