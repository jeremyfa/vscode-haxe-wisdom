package;

import vscode.ConfigurationTarget;
import vscode.ExtensionContext;
import wisdom.lsp.HxmlDefines;
import wisdom.lsp.TailwindSettings;

/**
 * Gets Tailwind CSS IntelliSense working inside Wisdom markup.
 *
 * We do not complete Tailwind classes ourselves (see `TailwindSettings` for
 * why). What this does is notice that a project uses Tailwind -- by
 * convention, `-D wisdom_tailwind` somewhere in its hxml chain -- and then
 * make sure the official extension is installed and configured for `.hx`
 * files, asking before touching either.
 *
 * Every prompt is shown once per workspace; `Wisdom: Configure Tailwind
 * IntelliSense` repeats the whole thing on demand.
 */
class TailwindIntegration {

    static inline var DEFINE = "wisdom_tailwind";
    static inline var MEMENTO_INSTALL_DISMISSED = "wisdom.tailwind.installDismissed";
    static inline var MEMENTO_CONFIGURE_DISMISSED = "wisdom.tailwind.configureDismissed";

    final context:ExtensionContext;
    final resolver:HaxeDisplayArgumentsResolver;
    final log:String->Void;

    /** Not asked twice in one session either, whatever the memento says. */
    var promptedThisSession:Bool = false;

    public function new(context:ExtensionContext, resolver:HaxeDisplayArgumentsResolver, log:String->Void) {
        this.context = context;
        this.resolver = resolver;
        this.log = log;
    }

    /// Detection

    /**
     * Does this project use Tailwind, as far as we can tell?
     *
     * `auto` looks for the define in the resolved arguments and the hxml files
     * they include -- the same scan that decides the HTML backend.
     */
    public function isActive():{active:Bool, source:String} {

        final mode:String = Vscode.workspace.getConfiguration("wisdom").get("tailwind");
        return switch mode {
            case "on": {active: true, source: "setting:on"};
            case "off": {active: false, source: "setting:off"};
            case _:
                final root = resolver.workspaceRoot();
                if (resolver.current == null || root == null) {
                    {active: false, source: "no-configuration"};
                }
                else {
                    final hit = HxmlDefines.find(resolver.current.arguments, root, DEFINE);
                    hit == null
                        ? {active: false, source: "not-detected"}
                        : {active: true, source: "detected:" + (hit.file != null ? hit.file : "arguments")};
                }
        }

    }

    /** Called after every configuration refresh. Prompts at most once. */
    public function check():Void {

        final state = isActive();
        if (!state.active) return;
        if (promptedThisSession) return;

        if (!isExtensionInstalled()) {
            if (context.workspaceState.get(MEMENTO_INSTALL_DISMISSED) == true) return;
            promptedThisSession = true;
            promptInstall();
            return;
        }

        if (isConfigured()) return;
        if (context.workspaceState.get(MEMENTO_CONFIGURE_DISMISSED) == true) return;
        promptedThisSession = true;
        promptConfigure();

    }

    /// The command

    public function configureCommand():Void {

        if (!isExtensionInstalled()) {
            promptInstall();
            return;
        }

        if (isConfigured()) {
            Vscode.window.showInformationMessage("Wisdom: Tailwind CSS IntelliSense is already configured for Wisdom markup.");
            return;
        }

        apply().then(_ -> {
            Vscode.window.showInformationMessage("Wisdom: Tailwind CSS IntelliSense is now configured for Wisdom markup.");
            return null;
        });

    }

    /// Prompts

    function promptInstall():Void {

        Vscode.window.showInformationMessage(
            "Wisdom: this project uses Tailwind. Install Tailwind CSS IntelliSense to get class completion and hover inside Wisdom markup?",
            "Install", "Don't ask again"
        ).then(choice -> {
            switch choice {
                case "Install":
                    Vscode.commands.executeCommand("workbench.extensions.installExtension", TailwindSettings.EXTENSION_ID)
                        .then(_ -> {
                            log("Tailwind CSS IntelliSense installed; configuring it for Wisdom markup.");
                            // The extension may not have activated yet, but its
                            // settings can be written regardless.
                            return apply();
                        });
                case "Don't ask again":
                    context.workspaceState.update(MEMENTO_INSTALL_DISMISSED, true);
                case _:
            }
            return choice;
        });

    }

    function promptConfigure():Void {

        Vscode.window.showInformationMessage(
            "Wisdom: configure Tailwind CSS IntelliSense for Wisdom markup? "
            + "This adds `haxe` to `tailwindCSS.includeLanguages` and class regexes to this workspace's settings.",
            "Configure", "Later", "Don't ask again"
        ).then(choice -> {
            switch choice {
                case "Configure":
                    apply().then(_ -> {
                        Vscode.window.showInformationMessage("Wisdom: Tailwind CSS IntelliSense is now configured for Wisdom markup.");
                        return null;
                    });
                case "Don't ask again":
                    context.workspaceState.update(MEMENTO_CONFIGURE_DISMISSED, true);
                case _:
            }
            return choice;
        });

    }

    /// Settings

    function isExtensionInstalled():Bool {
        return Vscode.extensions.getExtension(TailwindSettings.EXTENSION_ID) != null;
    }

    function isConfigured():Bool {
        return TailwindSettings.isConfigured(currentValues());
    }

    /**
     * The values to merge into: what the workspace already sets, or else what
     * is in effect (Tailwind's defaults), so that adding `classes` keeps
     * `class` and `className` rather than replacing them.
     */
    function currentValues():TailwindValues {

        final config = Vscode.workspace.getConfiguration("tailwindCSS");

        inline function workspaceOrEffective<T>(key:String):Null<T> {
            final inspected:Dynamic = config.inspect(key);
            if (inspected != null && inspected.workspaceValue != null) return inspected.workspaceValue;
            return config.get(key);
        }

        return {
            includeLanguages: workspaceOrEffective("includeLanguages"),
            classAttributes: workspaceOrEffective("classAttributes"),
            classRegex: workspaceOrEffective("experimental.classRegex")
        };

    }

    /**
     * Write our additions into the workspace settings, merging with whatever
     * is there. Never removes or overwrites a user value.
     */
    function apply():js.lib.Promise<Dynamic> {

        final merged = TailwindSettings.merge(currentValues());
        if (merged == null) return js.lib.Promise.resolve(null);

        final config = Vscode.workspace.getConfiguration("tailwindCSS");
        final target = ConfigurationTarget.Workspace;

        return js.lib.Promise.resolve(null)
            .then(_ -> config.update("includeLanguages", merged.includeLanguages, target))
            .then(_ -> config.update("classAttributes", merged.classAttributes, target))
            .then(_ -> config.update("experimental.classRegex", merged.classRegex, target))
            .then(_ -> {
                log("Tailwind CSS IntelliSense configured for Wisdom markup (workspace settings).");
                return null;
            })
            .catchError(error -> {
                log('Could not write Tailwind settings: $error');
                Vscode.window.showErrorMessage('Wisdom: could not update the workspace settings: $error');
                return null;
            });

    }

}
