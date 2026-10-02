var original = ["alpha", "beta"];
var combined = original.concat(["gamma"], "delta");
var queue = ["first", "second", "third"];
var undefinedValues = [undefined];
var shifted = queue.shift();
var rounds = 0;
var checksum = 0;
while (rounds < 10000) {
    var work = original.concat(["gamma"]);
    checksum += work.indexOf("gamma");
    checksum += "--custom-property".startsWith("--") ? 1 : 0;
    rounds++;
}
if (combined.length == 4 && combined[2] == "gamma" && combined[3] == "delta" &&
    combined.indexOf("beta", -3) == 1 && combined.indexOf("missing") == -1 &&
    shifted == "first" && queue.length == 2 && queue[0] == "second" &&
    "alpha-beta".concat("-gamma", 7) == "alpha-beta-gamma7" &&
    "alpha-beta".indexOf("beta", 3) == 6 && "alpha-beta".indexOf("") == 0 &&
    undefinedValues.indexOf() == 0 &&
    "--custom-property".startsWith("--", 0) && !"--custom-property".startsWith("custom") &&
    "2x".startsWith(2) &&
    checksum == 30000) {
    print("PASS runtime array and string methods");
} else {
    print("FAIL runtime array and string methods");
}
