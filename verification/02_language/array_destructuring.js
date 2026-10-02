var [first, , third] = [4, 5, 6];
if (first !== 4 || third !== 6) throw "array destructuring mismatch";
print("PASS destructuring.array");
print("FIXTURE_DONE array_destructuring");
