if (encodeURIComponent("a b/!") !== "a%20b%2F!") throw "URI component encoding mismatch";
if (encodeURIComponent("\xE9") !== "%C3%A9") throw "UTF-8 URI component encoding mismatch";
var tool = { function: { name: "search" } };
if (tool.function.name !== "search") throw "keyword property name mismatch";
print("PASS encodeURIComponent");
print("FIXTURE_DONE uri_encoding");
