// Ordinary constructors, receiver binding and method dispatch (class lowering).
function Record(value) { this.value = value; }
var checksum = 0;
for (var run = 0; run < 15000; run++) checksum += new Record(run & 7).value;
if (checksum !== 52500) throw "constructor/this checksum";
print("PASS constructor benchmark");
