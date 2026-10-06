var count = 8192;
var length = 1024;
var checksum = 0;
var round = 0;
while (round < count) {
	var values = new Array(length);
	checksum = checksum + values.length;
	round = round + 1;
}
print(checksum);
