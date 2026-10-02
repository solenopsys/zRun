// Array/object spread and fixed-arity call spread lowerings with fresh results.
function sum(left, right) { return left + right; }
var checksum = 0, present = {value: 3};
for (var run = 0; run < 30000; run++) {
    var args = [present.value, 2];
    var first = args[0], second = args[1];
    var copy = {value: first};
    checksum += sum(first, second) + [first, second][0] + copy.value;
}
if (checksum !== 330000) throw "lowered spread checksum";
print("PASS spread benchmark");
