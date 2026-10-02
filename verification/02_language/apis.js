function check(name, fn, expected) {
    try {
        if (fn() === expected) print("PASS " + name);
        else print("FAIL " + name);
    } catch (e) { print("UNAVAILABLE " + name); }
}
check("api.Array.isArray", function () { return Array.isArray([1]); }, true);
check("api.JSON.parse", function () { return JSON.parse('{"x":7}').x; }, 7);
check("api.JSON.stringify", function () { return JSON.stringify({x:7}); }, '{"x":7}');
check("api.Math.imul", function () { return Math.imul(0x12345678, 123); }, -1088058456);
check("api.Object.assign", function () { return Object.assign({}, {x:7}).x; }, 7);
check("api.Object.entries", function () { return Object.entries({x:7})[0][1]; }, 7);
check("api.Object.fromEntries", function () { return Object.fromEntries([["x",7]]).x; }, 7);
check("api.Object.keys", function () { return Object.keys({x:7})[0]; }, "x");
check("api.Object.values", function () { return Object.values({x:7})[0]; }, 7);
print("FIXTURE_DONE apis");
