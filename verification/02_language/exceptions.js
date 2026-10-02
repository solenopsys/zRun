function fail() {
	throw "expected";
}

var caught = false;
try {
	fail();
} catch (error) {
	caught = error === "expected";
}

print(caught);
