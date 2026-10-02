var sum = 0;
for (var left = 1, right = 2; left < 4; left++) {
    sum += left + right;
}
var index = 0;
var offset = 0;
for (; index < 2; index++, offset += 2) {
}
if (sum == 12 && offset == 4) {
    print("PASS for declarations");
} else {
    print("FAIL for declarations");
}
