// Template interpolation lowering, string concatenation and SSR escaping work.
function render(id, label) {
    return "<li data-id=\"" + id + "\"><span>" + label + "</span></li>";
}
var checksum = 0;
for (var run = 0; run < 12000; run++) {
    var html = render(run, "item-" + (run & 15));
    checksum += html.length;
}
if (checksum !== 521390) throw "SSR/template checksum";
print("PASS SSR benchmark");
