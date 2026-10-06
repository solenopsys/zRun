var count = 2048;
var length = 1024;
var checksum = 0;
var round = 0;
while (round < count) {
	var bytes = new Uint8Array(length);
	var i = 0;
	while (i < length) {
		bytes[i] = (i + round) % 251;
		i = i + 1;
	}
	i = 0;
	while (i < length) {
		checksum = checksum + bytes[i];
		i = i + 1;
	}
	round = round + 1;
}
print(checksum);
