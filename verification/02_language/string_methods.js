function check(name, fn, expected) {
    try {
        if (fn() === expected) print("PASS " + name);
        else print("FAIL " + name);
    } catch (e) { print("UNAVAILABLE " + name); }
}
check("method.charCodeAt", function () { return "A".charCodeAt(0); }, 65);
check("method.localeCompare", function () { return "a".localeCompare("b") < 0; }, true);
check("method.padStart", function () { return "7".padStart(3,"0"); }, "007");
check("method.replace", function () { return "aba".replace("b","x"); }, "axa");
check("method.replaceAll", function () { return "aba".replaceAll("a","x"); }, "xbx");
check("method.toLowerCase", function () { return "ABC".toLowerCase(); }, "abc");
check("method.toString", function () { return (7).toString(); }, "7");
check("method.toUpperCase", function () { return "abc".toUpperCase(); }, "ABC");
check("method.trim", function () { return " x ".trim(); }, "x");
print("FIXTURE_DONE string_methods");
