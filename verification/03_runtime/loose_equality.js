var same_string = "key" == "key";
var nullish = null == undefined;
var boolean_number = true == 1 && false != 1;
var different_numbers = 2 != 3;
if (same_string && nullish && boolean_number && different_numbers) {
    print("PASS loose equality");
} else {
    print("FAIL loose equality");
}
