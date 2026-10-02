function check(name, fn, expected) {
    try {
        if (fn() === expected) print("PASS " + name);
        else print("FAIL " + name);
    } catch (e) { print("UNAVAILABLE " + name); }
}
function plus(a, b) { return a + b; }
check("method.bind", function () { return plus.bind(null, 2)(3); }, 5);
check("method.call", function () { return plus.call(null, 2, 3); }, 5);
print("FIXTURE_DONE function_methods");
