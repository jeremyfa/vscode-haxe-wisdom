package;

import haxe.DynamicAccess;
import js.node.Fs;
import js.node.Path;
import wisdom.lsp.HxmlDefines;
import wisdom.lsp.WisdomProtocol;

using StringTools;

typedef ResolvedConfiguration = {
    var label:String;
    var arguments:Array<String>;
    var source:String;
}

/**
 * Works out which compiler arguments Wisdom's own Haxe server should run with.
 *
 * vshaxe does not expose the arguments it is using: its public API offers
 * `registerDisplayArgumentsProvider` (a push API, for *supplying* arguments)
 * and `getActiveConfiguration()` (class paths and defines, with libraries
 * already flattened, so `--macro` and `--remap` from a library's
 * `extraParams.hxml` are gone). The selected configuration index lives in
 * vshaxe's private workspace memento.
 *
 * So we mirror what vshaxe's built-in provider does -- read `haxe.configurations`,
 * fall back to HXML files at the workspace root -- and pass the arguments
 * through untouched, letting `haxe --cwd <root>` read the HXML itself with its
 * includes, its `-lib` entries and any project-local `.haxelib`. When a project
 * is driven by a third-party provider instead (Lime, OpenFL, Ceramic), mirroring
 * would be wrong, which is what `wisdom.displayArguments` is for.
 *
 * We deliberately do not register a provider of our own: Wisdom is a library,
 * not a project system, and taking the active-provider slot would break vshaxe
 * for exactly those users.
 */
class HaxeDisplayArgumentsResolver {

    static inline var MEMENTO_INDEX = "wisdom.configurationIndex";
    static inline var MEMENTO_WARNED = "wisdom.warnedNoConfiguration";

    public var current(default, null):Null<ResolvedConfiguration> = null;

    /** Every configuration we could offer, for `Wisdom: Select Haxe Configuration`. */
    public var candidates(default, null):Array<ResolvedConfiguration> = [];

    final context:vscode.ExtensionContext;
    final vshaxe:Null<Vshaxe>;
    final log:String->Void;

    public function new(context:vscode.ExtensionContext, vshaxe:Null<Vshaxe>, log:String->Void) {
        this.context = context;
        this.vshaxe = vshaxe;
        this.log = log;
    }

    public function workspaceRoot():Null<String> {

        final folders = Vscode.workspace.workspaceFolders;
        if (folders == null || folders.length == 0) return null;
        return folders[0].uri.fsPath;

    }

    /**
     * Recompute, and report whether the result differs from what we held.
     */
    public function refresh():Bool {

        final previous = current;
        candidates = collectCandidates();
        current = select();

        final before = previous == null ? null : previous.arguments.join(" ");
        final after = current == null ? null : current.arguments.join(" ");
        return before != after;

    }

    public function selectIndex(index:Int):Void {

        context.workspaceState.update(MEMENTO_INDEX, index);
        refresh();

    }

    /// Resolution

    function select():Null<ResolvedConfiguration> {

        final config = Vscode.workspace.getConfiguration("wisdom");

        // 1. Explicit settings win outright: they exist precisely for the
        //    projects our mirroring cannot get right.
        final explicit:Array<String> = config.get("displayArguments");
        if (explicit != null && explicit.length > 0) {
            return {label: "wisdom.displayArguments", arguments: explicit.copy(), source: "wisdom.displayArguments"};
        }

        final hxmlFile:String = config.get("hxmlFile");
        if (hxmlFile != null && hxmlFile.trim() != "") {
            return {label: hxmlFile, arguments: [hxmlFile.trim()], source: "wisdom.hxmlFile"};
        }

        if (candidates.length == 0) return null;

        // 2. A configuration whose `files` globs match the file being edited.
        final active = Vscode.window.activeTextEditor;
        if (active != null) {
            final root = workspaceRoot();
            if (root != null) {
                final relative = relativeTo(root, active.document.uri.fsPath);
                for (candidate in candidates) {
                    final globs = globsFor(candidate);
                    for (glob in globs) {
                        if (matchesGlob(glob, relative)) return candidate;
                    }
                }
            }
        }

        // 3. Whatever the user last picked, then the first one.
        final remembered:Null<Int> = context.workspaceState.get(MEMENTO_INDEX);
        if (remembered != null && remembered >= 0 && remembered < candidates.length) {
            return candidates[remembered];
        }

        return candidates[0];

    }

    final globs:Map<String, Array<String>> = [];

    inline function globsFor(candidate:ResolvedConfiguration):Array<String> {
        final found = globs.get(candidate.source);
        return found != null ? found : [];
    }

    function collectCandidates():Array<ResolvedConfiguration> {

        globs.clear();
        final found:Array<ResolvedConfiguration> = [];

        final haxeConfig = Vscode.workspace.getConfiguration("haxe");
        var raw:Array<Dynamic> = haxeConfig.get("configurations");
        if (raw == null || raw.length == 0) raw = haxeConfig.get("displayConfigurations");

        if (raw != null) {
            for (index in 0...raw.length) {
                final entry:Dynamic = raw[index];
                final source = 'haxe.configurations[$index]';

                if (Std.isOfType(entry, Array)) {
                    final args:Array<String> = entry;
                    found.push({label: args.join(" "), arguments: args.copy(), source: source});
                }
                else if (entry != null && entry.args != null) {
                    final args:Array<String> = entry.args;
                    final label:String = entry.label != null ? entry.label : args.join(" ");
                    found.push({label: label, arguments: args.copy(), source: source});
                    if (entry.files != null) globs.set(source, entry.files);
                }
            }
        }

        // HXML files at the workspace root, the way vshaxe discovers them.
        final root = workspaceRoot();
        if (root != null) {
            for (name in listRootHxml(root)) {
                // `extraParams.hxml` is a library's own contribution, never a
                // build of this project.
                if (name == "extraParams.hxml") continue;
                var alreadyListed = false;
                for (candidate in found) {
                    if (candidate.arguments.length == 1 && candidate.arguments[0] == name) alreadyListed = true;
                }
                if (alreadyListed) continue;
                found.push({label: name, arguments: [name], source: 'hxml:$name'});
            }
        }

        return found;

    }

    function listRootHxml(root:String):Array<String> {

        try {
            final names = Fs.readdirSync(root);
            final hxml = [for (name in names) if (name.endsWith(".hxml")) (name : String)];
            hxml.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
            return hxml;
        }
        catch (_:Any) {
            return [];
        }

    }

    /// The Haxe executable

    public function haxeExecutable():{path:String, env:DynamicAccess<String>} {

        final own:String = Vscode.workspace.getConfiguration("wisdom").get("haxeExecutable");
        if (own != null && own.trim() != "") {
            return {path: own.trim(), env: {}};
        }

        if (vshaxe != null && vshaxe.haxeExecutable != null) {
            final configuration = vshaxe.haxeExecutable.configuration;
            // Already shell-escaped by vshaxe, which is why we spawn with a shell.
            return {path: configuration.executable, env: configuration.env};
        }

        // vshaxe absent: read `haxe.executable` the way it would have.
        return {path: readHaxeExecutableSetting(), env: {}};

    }

    function readHaxeExecutableSetting():String {

        final raw:Dynamic = Vscode.workspace.getConfiguration("haxe").get("executable");
        if (raw == null) return "haxe";

        if (Std.isOfType(raw, String)) {
            final value:String = raw;
            return value == "auto" || value == "" ? "haxe" : value;
        }

        // Object form, with per-OS overrides.
        final platform = js.Node.process.platform;
        final osKey = switch platform {
            case "win32": "windows";
            case "darwin": "osx";
            case _: "linux";
        }
        final override_:Dynamic = Reflect.field(raw, osKey);
        final base:Dynamic = override_ != null ? override_ : raw;

        final path:Dynamic = Std.isOfType(base, String) ? base : Reflect.field(base, "path");
        if (path == null) return "haxe";
        final value:String = path;
        return value == "auto" || value == "" ? "haxe" : value;

    }

    public function serverArguments():Array<String> {

        final displayServer:Dynamic = Vscode.workspace.getConfiguration("haxe").get("displayServer");
        if (displayServer == null || displayServer.arguments == null) return [];
        final args:Array<String> = displayServer.arguments;
        return args.copy();

    }

    /// Settings

    public function settings():WisdomSettings {

        final config = Vscode.workspace.getConfiguration("wisdom");

        inline function bool(key:String, fallback:Bool):Bool {
            final value:Null<Bool> = config.get(key);
            return value != null ? value : fallback;
        }
        inline function int(key:String, fallback:Int):Int {
            final value:Null<Float> = config.get(key);
            return value != null ? Std.int(value) : fallback;
        }

        final exclude:Array<String> = config.get("exclude");
        final trace:String = config.get("trace.haxeServer");

        return {
            enableTypedFeatures: bool("enableTypedFeatures", true),
            haxeServerEnabled: bool("haxeDisplayServer.enable", true),
            idleShutdown: int("haxeDisplayServer.idleShutdown", 300),
            requestTimeout: int("haxeDisplayServer.requestTimeout", 10),
            buildCompletionCache: bool("haxeDisplayServer.buildCompletionCache", true),
            maxCompletionItems: int("maxCompletionItems", 1000),
            exclude: exclude != null ? exclude : ["haxe.macro"],
            hoverEnabled: bool("hover.enable", true),
            definitionEnabled: bool("definition.enable", true),
            trace: trace != null ? trace : "off"
        };

    }

    /// The payload sent to the language server

    public function configuration(generation:Int):HaxeDisplayConfiguration {

        final root = workspaceRoot();
        final executable = haxeExecutable();
        final settings = this.settings();

        final enabled = settings.enableTypedFeatures && settings.haxeServerEnabled && root != null;
        final html = htmlBackend(root);

        return {
            generation: generation,
            workspaceRoot: root != null ? root : "",
            haxePath: executable.path,
            haxeEnv: executable.env,
            serverArguments: serverArguments(),
            displayArguments: enabled && current != null ? current.arguments : null,
            source: current != null ? current.source : (enabled ? "none" : "disabled"),
            htmlBackend: html.enabled,
            htmlBackendSource: html.source,
            settings: settings
        };

    }

    /**
     * Does the markup target the HTML backend?
     *
     * `auto` looks for `-D wisdom_html` in the resolved arguments and the HXML
     * files they include. It uses the resolved configuration even when the
     * typed features are switched off, because HTML documentation needs no
     * compiler. Nothing found means off: offering `<div>` to a project that
     * renders to something else would be wrong, not merely useless.
     */
    public function htmlBackend(root:Null<String>):{enabled:Bool, source:String} {

        final mode:String = Vscode.workspace.getConfiguration("wisdom").get("htmlBackend");

        return switch mode {
            case "on": {enabled: true, source: "setting:on"};
            case "off": {enabled: false, source: "setting:off"};
            case _:
                if (current == null || root == null) {
                    {enabled: false, source: "no-configuration"};
                }
                else {
                    final hit = HxmlDefines.find(current.arguments, root, "wisdom_html");
                    if (hit == null) {enabled: false, source: "not-detected"};
                    else {enabled: true, source: "detected:" + (hit.file != null ? relativeTo(root, hit.file) : "arguments")};
                }
        }

    }

    /**
     * Warn once, without a modal, that nothing could be resolved.
     *
     * The offline half of completion keeps working, so this is informational.
     */
    public function warnIfUnresolved():Void {

        if (current != null) return;
        final settings = this.settings();
        if (!settings.enableTypedFeatures || !settings.haxeServerEnabled) return;
        if (context.workspaceState.get(MEMENTO_WARNED) == true) return;

        context.workspaceState.update(MEMENTO_WARNED, true);
        log("No Haxe configuration found; component completion, hover, go to definition and HTML documentation are disabled.");

        Vscode.window.showWarningMessage(
            "Wisdom: no Haxe configuration found, so component and HTML completion are unavailable. "
            + "Wisdom control tags still work; set `wisdom.htmlBackend` to `on` for HTML completion without a build file.",
            "Configure"
        ).then(choice -> {
            if (choice == "Configure") {
                Vscode.commands.executeCommand("workbench.action.openSettings", "wisdom.displayArguments");
            }
            return choice;
        });

    }

    /// Glob matching
    //
    // Only what `haxe.configurations[].files` actually uses: `**`, `*` and `?`.

    static function matchesGlob(glob:String, path:String):Bool {

        final pattern = new EReg("^" + globToRegex(glob) + "$", js.Node.process.platform == "win32" ? "i" : "");
        return pattern.match(path.replace("\\", "/"));

    }

    static function globToRegex(glob:String):String {

        final out = new StringBuf();
        var i = 0;
        while (i < glob.length) {
            final c = glob.charAt(i);
            switch c {
                case "*":
                    if (glob.charAt(i + 1) == "*") {
                        // `**/` may also match nothing at all.
                        if (glob.charAt(i + 2) == "/") {
                            out.add("(?:.*/)?");
                            i += 3;
                            continue;
                        }
                        out.add(".*");
                        i += 2;
                        continue;
                    }
                    out.add("[^/]*");
                case "?":
                    out.add("[^/]");
                case "." | "+" | "(" | ")" | "|" | "^" | "$" | "{" | "}" | "[" | "]" | "\\":
                    out.add("\\" + c);
                case _:
                    out.add(c);
            }
            i++;
        }
        return out.toString();

    }

    static function relativeTo(root:String, path:String):String {

        final relative = Path.relative(root, path);
        return relative.replace("\\", "/");

    }

}
