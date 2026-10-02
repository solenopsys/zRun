var value = null;
value ??= 7;
if (value !== 7) throw "nullish assignment mismatch";
print("PASS operator.assignment.??=");
print("FIXTURE_DONE nullish_assignment");
