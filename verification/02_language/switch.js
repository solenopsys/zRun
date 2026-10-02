var n = 2, out = "";
switch (n) {
case 1: out = "one"; break;
case 2: out = "two"; break;
default: out = "other";
}
if (out !== "two") throw "switch mismatch";
print("PASS control.switch/case/default");
print("FIXTURE_DONE switch");
