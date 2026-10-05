var x = 3;
x++;
x *= 4;
x /= 2;
x ^= 3;
x &= 15;
x |= 16;
if (x !== 27) throw "standalone updates";
var before = x++;
var after = ++x;
if (before !== 27 || after !== 29 || x !== 29) throw "used increment result";
function make() {
    var value = 2;
    return function() { value++; value *= 2; return value; };
}
var step = make();
if (step() !== 6 || step() !== 14) throw "captured updates";
function loop() { var n = 0; while (n < 10000) { n++; } return n; }
if (loop() !== 10000) throw "loop stack balance";
print("PASS update semantics");
