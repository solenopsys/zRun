function check(name, fn, expected) {
    try {
        if (fn() === expected) print("PASS " + name);
        else print("FAIL " + name);
    } catch (e) { print("UNAVAILABLE " + name); }
}
check("api.Map", function () { return new Map() instanceof Map; }, true);
check("Map.set", function () { var m = new Map(); return m.set("x", 7) === m; }, true);
check("Map.get", function () { var m = new Map(); m.set("x", 7); return m.get("x"); }, 7);
check("Map.has", function () { var m = new Map(); m.set("x", 7); return m.has("x"); }, true);
check("Map.keys", function () { var m = new Map(); m.set("x", 7); return m.keys().next().value; }, "x");
check("api.Set", function () { return new Set() instanceof Set; }, true);
check("Set.add", function () { var s = new Set(); return s.add("x") === s; }, true);
check("Set.has", function () { var s = new Set(); s.add("x"); return s.has("x"); }, true);
check("Set.values", function () { var s = new Set(); s.add("x"); return s.values().next().value; }, "x");
check("api.WeakMap", function () {
    var w = new WeakMap(), k = {}; w.set(k, 7); return w.get(k);
}, 7);
print("FIXTURE_DONE collections");
