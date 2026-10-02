function Box(value) { this.value = value; }
if (new Box(7).value !== 7) throw "construct mismatch";
print("PASS object.construct");
print("FIXTURE_DONE construct");
