class Box { constructor(value) { this.value = value; } }
if (new Box(7).value !== 7) throw "class mismatch";
print("PASS class.declaration");
print("FIXTURE_DONE class");
