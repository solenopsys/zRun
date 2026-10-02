var round = 0;
var checksum = 0;
while (round < 10000) {
    var values = [round, round + 1, round + 2].concat([round + 3], [round + 4]);
    var position = values.indexOf(round + 3, 2);
    var queue = values.concat();
    checksum += position + queue.shift();
    round++;
}
print(checksum);
