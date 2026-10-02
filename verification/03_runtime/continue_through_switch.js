var output = "";
var values = ["a", "b", "c"];
for (var index = 0; index < values.length; index++) {
    switch (values[index]) {
        case "a":
            output += "A";
            continue;
        case "b":
            output += "B";
            continue;
        default:
            output += "C";
    }
    output += "!";
}
print(output);
