// String trim/case/replace/charCodeAt; explicit lowering for padStart.
var checksum = 0;
for (var run = 0; run < 30000; run++) {
    var text = "  business-ZIG-17  ".trim().toLowerCase().replaceAll("i", "1");
    var padded = "17";
    while (padded.length < 6) padded = "0" + padded;
    var compare = text < "business-zig-18" ? 1 : 0;
    checksum += text.charCodeAt(0) + padded.charCodeAt(0) + compare;
}
if (checksum !== 147 * 30000) throw "string hot path checksum";
print("PASS string benchmark");
