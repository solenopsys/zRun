function check(name, fn, expected) {
    try {
        if (fn() === expected) print("PASS " + name);
        else print("FAIL " + name);
    } catch (e) { print("UNAVAILABLE " + name); }
}
check("method.filter", function () { return [1,2,3].filter(function (x) { return x > 1; }).length; }, 2);
check("method.find", function () { return [1,2,3].find(function (x) { return x > 1; }); }, 2);
check("method.flatMap", function () { return [1,2].flatMap(function (x) { return [x,x]; }).length; }, 4);
check("method.includes", function () { return [1,2,3].includes(2); }, true);
check("method.join", function () { return [1,2,3].join(","); }, "1,2,3");
check("method.map", function () { return [1,2,3].map(function (x) { return x * 2; })[2]; }, 6);
check("method.reduce", function () { return [1,2,3].reduce(function (a,x) { return a+x; }, 0); }, 6);
check("method.slice", function () { return [1,2,3].slice(1)[0]; }, 2);
check("method.some", function () { return [1,2,3].some(function (x) { return x === 2; }); }, true);
check("method.sort", function () { return [3,1,2].sort()[0]; }, 1);
print("FIXTURE_DONE array_methods");
