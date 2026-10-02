var empty = null;
if (empty?.x !== undefined) throw "optional access mismatch";
print("PASS property.optional-access");
print("FIXTURE_DONE optional_access");
