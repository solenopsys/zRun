var n = 2, out = "";
switch (n) {
case 1: out = "one"; break;
case 2: out = "two"; break;
default: out = "other";
}
if (out !== "two") throw "switch mismatch";
print("PASS control.switch/case/default");
var fallthrough = "";
switch (1) {
case 1: fallthrough = "first";
case 2: fallthrough += "+second"; break;
default: fallthrough = "default";
}
if (fallthrough !== "first+second") throw "switch fallthrough mismatch";
var evaluated = 0;
function laterCase() { evaluated++; return 3; }
var grouped = "";
switch (2) {
case 1:
case 2: grouped = "grouped"; break;
case laterCase(): grouped = "wrong"; break;
default: grouped = "default";
}
if (grouped !== "grouped" || evaluated !== 0) throw "grouped switch mismatch";
print("PASS control.switch/fallthrough-grouped");
print("FIXTURE_DONE switch");
