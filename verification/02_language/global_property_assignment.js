globalThis["dynamicHook"] = () => 7;
if (globalThis.dynamicHook() !== 7) throw "globalThis hook registration mismatch";
print("PASS globalThis computed assignment");
print("FIXTURE_DONE global_this_computed_assignment");
