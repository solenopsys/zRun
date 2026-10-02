var obj = { value: 7, get: function () { return this.value; } };
if (obj.get() !== 7) throw "this mismatch";
print("PASS keyword.this");
print("FIXTURE_DONE this");
