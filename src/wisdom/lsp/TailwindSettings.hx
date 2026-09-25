package wisdom.lsp;

import haxe.Json;

/** The three Tailwind CSS IntelliSense settings the integration touches. */
typedef TailwindValues = {
    var includeLanguages:Dynamic;
    var classAttributes:Array<String>;
    var classRegex:Array<Dynamic>;
}

/**
 * What Tailwind CSS IntelliSense needs to know to work inside Wisdom markup.
 *
 * Tailwind v4 is configured in CSS (`@import "tailwindcss"`, `@theme`,
 * `@source`): the set of valid classes, including a project's own tokens
 * such as `text-t-accent`, only exists once the entry CSS is compiled. The
 * official language server does that; reimplementing it would mean shipping
 * the whole Tailwind engine to duplicate a maintained tool. So instead of
 * completing classes ourselves, we point that server at Wisdom markup.
 *
 * It does not know Haxe, and its attribute detector only matches
 * `class="..."`-style values -- so three settings are needed: map `haxe` to
 * `html`, add Wisdom's `classes` alias, and give it regexes for the
 * `class=${'...'}` form, where the classes sit inside Haxe string literals.
 *
 * Pure Haxe, so the merge logic is testable without VSCode.
 */
class TailwindSettings {

    public static inline var EXTENSION_ID = "bradlc.vscode-tailwindcss";

    /** The language mapping: treat .hx like HTML. */
    public static inline var LANGUAGE = "haxe";
    public static inline var LANGUAGE_TARGET = "html";

    /** Wisdom's alias of `class`; `class` and `className` are already in Tailwind's defaults. */
    public static inline var EXTRA_ATTRIBUTE = "classes";

    /** Tailwind's own default `classAttributes`, for when the setting is unset. */
    public static final DEFAULT_ATTRIBUTES:Array<String> = ["class", "className", "ngClass", "class:list"];

    /**
     * Captures the body of `class=${...}` (one level of nested braces, enough
     * for `${{...}}`); the inner regex then picks each quoted Haxe literal, so
     * `class=${'relative w-11 ' + (on ? 'bg-a' : 'bg-b')}` yields three lists.
     */
    public static inline var CONTAINER_REGEX = "\\b(?:class|className|classes)=\\$\\{((?:[^{}]|\\{[^{}]*\\})*)\\}";
    public static inline var SINGLE_QUOTED_REGEX = "'([^']*)'";
    public static inline var DOUBLE_QUOTED_REGEX = "\"([^\"]*)\"";

    /** The two `tailwindCSS.experimental.classRegex` entries, in Tailwind's `[container, inner]` form. */
    public static final CLASS_REGEX_ENTRIES:Array<Array<String>> = [
        [CONTAINER_REGEX, SINGLE_QUOTED_REGEX],
        [CONTAINER_REGEX, DOUBLE_QUOTED_REGEX]
    ];

    /** True when every setting is already in place. */
    public static function isConfigured(values:TailwindValues):Bool {

        if (values.includeLanguages == null || Reflect.field(values.includeLanguages, LANGUAGE) != LANGUAGE_TARGET) return false;
        if (values.classAttributes == null || values.classAttributes.indexOf(EXTRA_ATTRIBUTE) == -1) return false;
        for (entry in CLASS_REGEX_ENTRIES) {
            if (!containsEntry(values.classRegex, entry)) return false;
        }
        return true;

    }

    /**
     * The settings with ours added, and nothing of the user's removed or
     * overwritten. Returns null when nothing needs to change.
     */
    public static function merge(values:TailwindValues):Null<TailwindValues> {

        var changed = false;

        final includeLanguages:Dynamic = values.includeLanguages != null ? copyObject(values.includeLanguages) : {};
        if (Reflect.field(includeLanguages, LANGUAGE) != LANGUAGE_TARGET) {
            Reflect.setField(includeLanguages, LANGUAGE, LANGUAGE_TARGET);
            changed = true;
        }

        final classAttributes = values.classAttributes != null ? values.classAttributes.copy() : DEFAULT_ATTRIBUTES.copy();
        if (classAttributes.indexOf(EXTRA_ATTRIBUTE) == -1) {
            classAttributes.push(EXTRA_ATTRIBUTE);
            changed = true;
        }

        final classRegex:Array<Dynamic> = values.classRegex != null ? values.classRegex.copy() : [];
        for (entry in CLASS_REGEX_ENTRIES) {
            if (!containsEntry(classRegex, entry)) {
                classRegex.push(entry);
                changed = true;
            }
        }

        return changed ? {includeLanguages: includeLanguages, classAttributes: classAttributes, classRegex: classRegex} : null;

    }

    static function containsEntry(list:Null<Array<Dynamic>>, entry:Array<String>):Bool {

        if (list == null) return false;
        final wanted = Json.stringify(entry);
        for (existing in list) {
            if (Json.stringify(existing) == wanted) return true;
        }
        return false;

    }

    static function copyObject(source:Dynamic):Dynamic {

        final copy = {};
        for (field in Reflect.fields(source)) Reflect.setField(copy, field, Reflect.field(source, field));
        return copy;

    }

}
