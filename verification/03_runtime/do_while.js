var index = 0;
var result = 0;
do {
    index++;
    if (index < 3) continue;
    result = index;
} while (index < 4);
if (index == 4 && result == 4) {
    print("PASS do while");
} else {
    print("FAIL do while");
}
