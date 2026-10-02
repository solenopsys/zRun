var values = [2, 3], copy = [...values];
if (copy.length !== 2 || copy[1] !== 3) throw "array spread mismatch";
print("PASS spread.array");
print("FIXTURE_DONE array_spread");
