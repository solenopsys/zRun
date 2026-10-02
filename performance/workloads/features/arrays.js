// Array map/filter/reduce/some/sort; loop lowering for find/includes/flatMap.
function twice(value) { return value * 2; }
function keepLarge(value) { return value > 10; }
function add(left, right) { return left + right; }
function firstAbove(values, limit) {
    for (var i = 0; i < values.length; i++) if (values[i] > limit) return values[i];
    return undefined;
}
function contains(values, target) {
    for (var i = 0; i < values.length; i++) if (values[i] === target) return true;
    return false;
}
function flattenTwice(values) {
    var result = [];
    for (var i = 0; i < values.length; i++) {
        result[result.length] = values[i];
        result[result.length] = values[i] * 2;
    }
    return result;
}
var source = [1,2,3,4,5,6,7,8,9,10], checksum = 0;
for (var run = 0; run < 4000; run++) {
    var mapped = source.map(twice);
    var filtered = mapped.filter(keepLarge);
    var found = firstAbove(mapped, 10);
    var flattened = flattenTwice(source);
    checksum += filtered.reduce(add, 0) + found + flattened.length;
    if (!source.some(function (value) { return value === 7; })) throw "some";
    if (!contains(source, 7)) throw "includes lowering";
}
if (checksum !== 448000) throw "array hot path checksum";
print("PASS array benchmark");
