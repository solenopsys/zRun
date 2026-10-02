// JSON parse/stringify allocation and primitive conversion.
var checksum = 0;
for (var run = 0; run < 12000; run++) {
    var value = JSON.parse('{"id":17,"active":true}');
    var encoded = JSON.stringify(value);
    if (encoded.length !== 23) throw "json length";
    checksum += value.id;
}
if (checksum !== 204000) throw "json hot path checksum";
print("PASS JSON benchmark");
