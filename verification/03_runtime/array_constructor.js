var values = new Array(3);
if (values.length != 3 || values[0] != undefined || values[2] != undefined) {
    print("FAIL sparse array constructor defaults");
}
values[0] = "a";
values[1] = "b";
values[2] = "c";
if (values.length == 3 && values[2] == "c") {
    print("PASS array constructor");
} else {
    print("FAIL array constructor");
}
