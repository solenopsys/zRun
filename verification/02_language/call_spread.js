function sum(a, b) { return a + b; }
var values = [2, 3];
if (sum(...values) !== 5) throw "call spread mismatch";
print("PASS spread.call-arguments");
print("FIXTURE_DONE call_spread");
