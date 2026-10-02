var predicate = function (value) { return value == 1; };
var marker = /['{]/;
function check(value) {
    return predicate(value) && later(value);
}
function later(value) { return value == 1; }
if (check(1)) {
    print("PASS hoisted local capture");
} else {
    print("FAIL hoisted local capture");
}
