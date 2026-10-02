// Math.imul, unsigned shift, typeof, in and instanceof hot paths.
var box = {}, checksum = 0;
box.value = 7;
for (var run = 0; run < 50000; run++) {
    var product = Math.imul(run, 3) >>> 1;
    if ("value" in box && typeof product === "number") checksum += product & 1;
}
if (checksum !== 25000 || !(new Error() instanceof Error)) throw "numeric/operator checksum";
print("PASS numeric benchmark");
