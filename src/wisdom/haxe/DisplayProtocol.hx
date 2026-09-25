package wisdom.haxe;

/**
 * The slice of Haxe's JSON-RPC display protocol we use.
 *
 * Mirrors `std/haxe/display/Display.hx` and `JsonModuleTypes.hx` from the Haxe
 * standard library. Only what the Wisdom probes actually read is typed; the
 * rest stays `Dynamic` rather than pretending to a completeness we would then
 * have to maintain against every Haxe release.
 */

/**
 * `offset` counts **Unicode codepoints**, not UTF-16 code units, and `contents`
 * replaces the content of a file that must exist on disk.
 */
typedef PositionParams = {
    var file:String;
    var offset:Int;
    var ?contents:String;
}

typedef CompletionParams = {
    > PositionParams,
    var wasAutoTriggered:Bool;
    var ?meta:Array<String>;
}

typedef DisplayPosition = {
    var line:Int;
    /** Codepoint index within the line, not a UTF-16 column. */
    var character:Int;
}

typedef DisplayRange = {
    var start:DisplayPosition;
    var end:DisplayPosition;
}

typedef DisplayLocation = {
    var file:String;
    var range:DisplayRange;
}

/**
 * `kind` is one of Local, ClassField, EnumField, EnumAbstractField, Type,
 * Package, Module, Literal, Metadata, Keyword, AnonymousStructure, Expression,
 * TypeParameter, Define. `args` is shaped by `kind`.
 */
typedef DisplayItem = {
    var kind:String;
    var args:Dynamic;
    var ?type:JsonType;
    /** Only present when `initialize` was sent with `supportsResolve`. */
    var ?index:Int;
}

typedef JsonType = {
    var kind:String;
    var args:Dynamic;
}

typedef JsonTypePath = {
    var pack:Array<String>;
    var moduleName:String;
    var typeName:String;
    /** 0 usable unqualified, 1 not imported, 2 shadowed. */
    var ?importStatus:Int;
}

/** `args` of a `Type` item. */
typedef DisplayModuleType = {
    var path:JsonTypePath;
    var ?pos:JsonPos;
    var isPrivate:Bool;
    var meta:Array<JsonMetaEntry>;
    var ?doc:String;
    var isExtern:Bool;
    var isFinal:Bool;
    var isAbstract:Bool;
    /** 0 Class, 1 Interface, 2 Enum, 3 Abstract, 4 EnumAbstract, 5 TypeAlias, 6 Struct. */
    var kind:Int;
    var ?params:Array<{var name:String;}>;
}

/** `args` of a `ClassField` item. */
typedef DisplayClassField = {
    var field:JsonClassField;
    var ?origin:Dynamic;
    var ?resolution:Dynamic;
}

typedef JsonClassField = {
    var name:String;
    var type:JsonType;
    var ?params:Array<{var name:String;}>;
    var isPublic:Bool;
    var isFinal:Bool;
    /** 0 Static, 1 Member, 2 Constructor. */
    var ?scope:Int;
    var meta:Array<JsonMetaEntry>;
    var ?doc:String;
    var ?pos:JsonPos;
    /** The initializer, printed, when the field has one: `@props var label:String = ''`. */
    var ?expr:{var string:String;};
}

typedef JsonMetaEntry = {
    var name:String;
    var ?args:Array<Dynamic>;
    var ?pos:JsonPos;
}

typedef JsonPos = {
    var file:String;
    var min:Int;
    var max:Int;
}

/**
 * `mode.kind`: 0 Field, 1 StructureField, 2 Toplevel, 3 Metadata, 4 TypeHint,
 * 5 Extends, 6 Implements, 7 StructExtension, 8 Import, 9 Using, 10 New,
 * 11 Pattern, 12 Override, 13 TypeRelation, 14 TypeDeclaration.
 */
typedef CompletionResult = {
    var items:Array<DisplayItem>;
    var mode:{var kind:Int; var ?args:Dynamic;};
    /** 1-based, and computed against the buffer we sent. We use our own instead. */
    var ?replaceRange:DisplayRange;
    var ?isIncomplete:Bool;
    var ?filterString:String;
}

typedef HoverResult = {
    var item:DisplayItem;
    var ?documentation:String;
    var ?range:DisplayRange;
    var ?expected:Dynamic;
}

class CompletionModeKind {
    public static inline var Field = 0;
    public static inline var Toplevel = 2;
}

class DisplayMethods {
    public static inline var Completion = "display/completion";
    public static inline var CompletionItemResolve = "display/completionItem/resolve";
    public static inline var Hover = "display/hover";
    public static inline var Definition = "display/definition";
    public static inline var Initialize = "initialize";
    public static inline var ServerConfigure = "server/configure";
    public static inline var ServerInvalidate = "server/invalidate";
    public static inline var ServerModuleCreated = "server/moduleCreated";
    public static inline var ServerReadClassPaths = "server/readClassPaths";
}
