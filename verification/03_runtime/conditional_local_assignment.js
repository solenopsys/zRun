var name = "ref";
var key = 0;
var ref = 0;
var other = 0;
name == "key" ? key = 1 : name == "ref" ? ref = 2 : other = 3;
if (key == 0 && ref == 2 && other == 0) {
    print("PASS conditional local assignment");
} else {
    print("FAIL conditional local assignment");
}
