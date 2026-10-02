function collect(first) {
    return arguments.length * 100 + arguments[2];
}

if (collect(1, 2, 3) == 303) {
    print("PASS arguments object");
} else {
    print("FAIL arguments object");
}
