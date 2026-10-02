function readValue() {
    return this.value;
}
var receiver = {value: 41};
var bound = readValue.bind(receiver);
if (readValue.call(receiver) == 41 && bound() == 41) {
    print("PASS call and bind this");
} else {
    print("FAIL call and bind this");
}
