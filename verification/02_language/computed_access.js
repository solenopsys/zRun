var obj = {x: 7}, key = "x";
if (obj[key] !== 7) throw "computed access mismatch";
print("PASS property.computed-access");
print("FIXTURE_DONE computed_access");
