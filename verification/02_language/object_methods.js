var bias = 3;
var service = {
    base: 4,
    add(value) { return bias + value; },
    read() { return this.base; }
};
if (service.add(7) !== 10) throw "method closure mismatch";
if (service.read() !== 4) throw "method receiver mismatch";
print("PASS function.method");
print("FIXTURE_DONE object_methods");
