// Specialized string Map/Set lowering; object-key table is the string-key case.
var table = {}, unique = {}, checksum = 0;
for (var run = 0; run < 25000; run++) {
    var key = "k" + (run % 32);
    table["$" + key] = run;
    unique["$" + key] = true;
    if (unique["$" + key]) checksum += table["$" + key] & 1;
}
if (checksum !== 12500 || Object.keys(unique).length !== 32) throw "collection lowering checksum";
print("PASS collection benchmark");
