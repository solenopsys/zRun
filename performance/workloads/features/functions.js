// Function call/bind dispatch and captured lexical state used by arrow lowering.
function add(left, right) { return left + right; }
var addTwo = add.bind(null, 2), checksum = 0;
for (var run = 0; run < 50000; run++) checksum += addTwo(run & 7);
if (checksum !== 275000) throw "function hot path checksum";
print("PASS function benchmark");
