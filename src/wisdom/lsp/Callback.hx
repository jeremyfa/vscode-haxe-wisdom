package wisdom.lsp;

import wisdom.lsp.Protocol;

/**
 * Callbacks rather than `js.lib.Promise`, so that `Server` and the feature
 * handlers stay platform-agnostic: only `WisdomServer` (the Node/JSON-RPC
 * adapter) knows about promises.
 */
typedef Resolve<T> = (result:T) -> Void;

typedef Reject = (error:ResponseError) -> Void;
