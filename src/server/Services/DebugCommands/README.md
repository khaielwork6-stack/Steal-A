Studio-only debug command sets. Each ModuleScript here returns a table of
`name = function(player, ...)` handlers that DebugService merges into its
command list at start. Invoke them like any other command through
`ServerStorage.DebugInvoke` or the `DebugRequest` attribute bridge.
