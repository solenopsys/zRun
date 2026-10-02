var props = {title: "Tool & Parts"};
var name = "title";
var rest = {};
true ? rest[name] = props[name] : undefined;
if (rest.title == "Tool & Parts") {
    print("PASS conditional computed assignment");
} else {
    print("FAIL conditional computed assignment");
}
