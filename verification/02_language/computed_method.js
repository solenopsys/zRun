var methodName = "read";
var target = {
	base: 39,
	[methodName](increment) {
		return this.base + increment;
	},
};

if (target[methodName](3) !== 42) throw "computed method receiver mismatch";
print("PASS object.computed-method");
print("FIXTURE_DONE computed_method");
