// switch/case/default and array for-of lowering into indexed loops.
var values = [1,2,3,4,5,6,7,8], checksum = 0;
for (var run = 0; run < 20000; run++) {
    var value = values[run & 7];
    switch (value) {
    case 1: checksum += 1; break;
    case 2: checksum += 2; break;
    case 3: checksum += 3; break;
    default: checksum += 4;
    }
}
if (checksum !== 65000) throw "control hot path checksum";
print("PASS control benchmark");
