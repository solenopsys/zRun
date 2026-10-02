function empty() {}

function run() {
	var i = 0;
	while (i < 700000) {
		empty();
		i = i + 1;
	}
	return i;
}

run();
