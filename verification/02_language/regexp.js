if (!/ab+c/i.test("ABBC")) throw "regexp mismatch";
if ("/some/path///".replace(/\/+$/g, "") !== "/some/path") throw "global regexp replacement mismatch";
function trimPath(spec) { return spec.storage.mountBase.replace(/\/+$/g, ""); }
if (trimPath({ storage: { mountBase: "/some/path///" } }) !== "/some/path") throw "nested regex replacement mismatch";
print("PASS literal.regexp");
print("FIXTURE_DONE regexp");
