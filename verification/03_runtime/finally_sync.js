var count = 0;
try {
    count = 1;
} finally {
    count++;
}
try {
    try {
        throw 9;
    } finally {
        count++;
    }
} catch (errorValue) {
    count += errorValue;
}
if (count == 12) {
    print("PASS synchronous finally");
} else {
    print("FAIL synchronous finally");
}
