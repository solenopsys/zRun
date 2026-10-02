var value = 3;
var before = value++;
var after = ++value;
if (before == 3 && after == 5 && value == 5) {
    print("PASS local increments");
} else {
    print("FAIL local increments");
}
