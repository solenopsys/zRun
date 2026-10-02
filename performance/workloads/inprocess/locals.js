function run() {
	var i = 0;
	var sum = 0;
	while (i < 400000) {
		sum = sum + 1;
		i = i + 1;
	}
	return sum;
}

run();
