var value = null ?? 7;
if (value !== 7) throw "nullish mismatch";
print("PASS operator.binary.??/nullish-coalescing");
print("FIXTURE_DONE nullish");
