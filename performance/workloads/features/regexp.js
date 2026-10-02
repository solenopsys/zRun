// Bounded regular-expression matching over business identifiers.
var pattern = /ab+c/i, checksum = 0;
for (var run = 0; run < 30000; run++) {
    if (pattern.test(run & 1 ? "ABBC" : "xy123")) checksum++;
}
if (checksum !== 15000) throw "regexp hot path checksum";
print("PASS regexp benchmark");
