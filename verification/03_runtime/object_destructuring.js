var source = {type: "main", props: {id: 7}};
var {type: tag, props: attributes} = source;
if (tag == "main" && attributes.id == 7) {
    print("PASS object destructuring");
} else {
    print("FAIL object destructuring");
}
