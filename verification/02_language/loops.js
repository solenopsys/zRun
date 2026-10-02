var record = {a: 1, b: 2}, total = 0, key, values = [3, 4], value;
for (key in record) total += record[key];
for (value of values) total += value;
if (total !== 10) throw "loop mismatch";
print("PASS loop.for-in/for-of");
print("FIXTURE_DONE loops");
