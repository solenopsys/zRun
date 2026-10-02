var empty = null, key = "x";
if (empty?.[key] !== undefined) throw "optional computed access mismatch";
print("PASS property.optional-computed-access");
print("FIXTURE_DONE optional_computed_access");
