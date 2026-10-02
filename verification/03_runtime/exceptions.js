var result = 0;
try {
    throw 42;
} catch (errorValue) {
    result = errorValue;
}
print(result);
