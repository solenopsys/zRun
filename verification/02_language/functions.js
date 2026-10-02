function add(a, b) {
	return a + b;
}

function factorial(n) {
	if (n <= 1) return 1;
	return n * factorial(n - 1);
}

function makeAdder(base) {
	return function (value) {
		return base + value;
	};
}

var addFive = makeAdder(5);
print(add(2, 3), factorial(5), addFive(4));
