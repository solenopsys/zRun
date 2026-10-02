// Object.keys/entries/values/assign lowering and computed property access.
var checksum = 0;
for (var run = 0; run < 12000; run++) {
    var source = {a: 1, b: 2, c: 3}, target = {};
    var keys = Object.keys(source);
    for (var i = 0; i < keys.length; i++) target[keys[i]] = source[keys[i]];
    checksum += target[keys[run % 3]];
}
if (checksum !== 24000) throw "object hot path checksum";
print("PASS object benchmark");
