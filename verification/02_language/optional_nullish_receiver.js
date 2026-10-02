let absent;
if (absent?.enabled !== undefined) throw "undefined optional receiver mismatch";
let explicitNull = null;
if (explicitNull?.enabled !== undefined) throw "null optional receiver mismatch";
let spec = {};
let logging = spec.logging;
if (!logging?.enabled) print("PASS optional missing nested field");
function checkMissingLogging(input) {
	const capturedLogging = input.logging;
	return !capturedLogging?.enabled;
}
if (!checkMissingLogging({})) throw "function optional receiver mismatch";
function nestedCalls(depth) {
	if (depth <= 0) return 0;
	return nestedCalls(depth - 1) + 1;
}
if (nestedCalls(20) !== 20) throw "call depth mismatch";
print("PASS property.optional-nullish-receiver");
print("FIXTURE_DONE optional_nullish_receiver");
