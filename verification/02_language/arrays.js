var values = [3, 5, 8];
values[1] = 7;
values.push(11);

var sum = 0;
for (var i = 0; i < values.length; i++) {
	sum += values[i];
}
print(values.length, values[1], sum);
