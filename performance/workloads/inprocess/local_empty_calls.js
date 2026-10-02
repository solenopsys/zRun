function empty() {}

function run() {
	var fn = empty;
	var i = 0;
	while (i < 700000) {
		fn();
		i = i + 1;
	}
	return i;
}

run();
