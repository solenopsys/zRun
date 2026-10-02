function addOne(value) {
	return value + 1;
}

function run() {
	var i = 0;
	var sum = 0;
	while (i < 700000) {
		sum = sum + addOne(1);
		i = i + 1;
	}
	return sum;
}

run();
