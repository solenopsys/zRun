var value = 0;
skip: {
    value = 1;
    if (value == 1) break skip;
    value = 2;
}
if (value == 1) {
    print("PASS labeled break");
} else {
    print("FAIL labeled break");
}
