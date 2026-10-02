var renderer = {
    render(id, label) {
        return "<li data-id=\"" + id + "\"><span>" + label + "</span></li>";
    }
};
var checksum = 0;
for (var run = 0; run < 12000; run++) {
    var html = renderer.render(run, "item-" + (run & 15));
    checksum += html.length;
}
if (checksum !== 521390) throw "object method SSR checksum";
print("PASS object method SSR benchmark");
