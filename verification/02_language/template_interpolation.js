var name = "Zig", greeting = `hello ${name}`;
if (greeting !== "hello Zig") throw "template interpolation mismatch";
print("PASS template.interpolated");
print("FIXTURE_DONE template_interpolation");
