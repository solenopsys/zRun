var props = {class: "product", "data-id": 7};
function identity(value) { return value; }
props = identity({class: "product", "data-id": 7});
function pack(first, second, third) { return first; }
function render({product}) { return pack("li", {class: "product", "data-id": product.id}, product.name); }
function k(tag, props) { return props; }
function ProductRow({product}) { return /* @__PURE__ */ k("li", {
    class: "product",
    "data-id": product.id
}, k("span", null, product.name), k("strong", null, product.price, " USD"), k("em", null, product.available ? "In stock" : "Sold out")); }
if (render({product: {id: 7, name: "x"}}) == "li") {
    print("PASS nested call arguments");
}
if (props.class == "product" && props["data-id"] == 7) {
    print("PASS reserved object keys");
} else {
    print("FAIL reserved object keys");
}
