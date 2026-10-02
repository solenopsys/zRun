var props = {key: "item-7", ref: "ignored", title: "Tool & Parts"};
var key;
var ref;
var rest = {};
for (var name in props) {
    name == "key" ? key = props[name] : name == "ref" ? ref = props[name] : rest[name] = props[name];
}
if (key == "item-7" && ref == "ignored" && rest.title == "Tool & Parts") {
    print("PASS Preact property partition");
} else {
    print("FAIL Preact property partition");
}
