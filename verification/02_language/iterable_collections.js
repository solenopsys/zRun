const unique = [...new Set(["a", "a", "b"])];
if (unique.join(",") !== "a,b") throw "Set iterable constructor mismatch";

const copied = [...new Set(new Set(unique))];
if (copied.join(",") !== "a,b") throw "Set iterator constructor mismatch";

const entries = new Map([["first", 1], ["second", 2]]);
if (entries.get("second") !== 2) throw "Map iterable constructor mismatch";

if (["", "kept"].filter(Boolean).join(",") !== "kept") throw "native callback mismatch";
if (("" || "fallback") !== "fallback") throw "empty string truthiness mismatch";
if ((0 || 42) !== 42) throw "number truthiness mismatch";

print("PASS collections.iterable-constructors");
print("FIXTURE_DONE iterable_collections");
