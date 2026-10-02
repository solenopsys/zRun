var value = 3;
var text = "a";
var flags = {bits: 3};
value += 4;
text += "b";
flags.bits &= 1;
if (value == 7 && text == "ab" && flags.bits == 1) {
    print("PASS compound assignments");
} else {
    print("FAIL compound assignments");
}
