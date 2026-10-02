var value = 3;
value ^= 1;
if (value !== 2) throw "xor assignment mismatch";
print("PASS operator.assignment.^=");
print("FIXTURE_DONE xor_assignment");
