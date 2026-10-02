var raw = "left\x00right";
if (raw.length !== 10) throw "hex escape mismatch";

var fields = "alpha,beta,".split(",");
if (fields.length !== 3 || fields[0] !== "alpha" || fields[1] !== "beta" || fields[2] !== "") {
    throw "string split mismatch";
}
var limited = "alpha,beta,gamma".split(",", 2);
if (limited.length !== 2 || limited[1] !== "beta") throw "string split limit mismatch";
var characters = "é".split("");
if (characters.length !== 1 || characters[0] !== "é") throw "empty separator split mismatch";

var remaining = 3;
remaining -= 1;
if (remaining !== 2) throw "minus assignment mismatch";

var total = 0;
for (var index = 3; index > 0; index -= 1) total += index;
if (total !== 6) throw "minus assignment loop update mismatch";
print("PASS Resonus runtime primitives");
print("FIXTURE_DONE host_runtime_primitives");
