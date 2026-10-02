function element(name, content) {
	return "<" + name + ">" + content + "</" + name + ">";
}

function render(title, count) {
	return element("h1", title) + element("p", "items:" + count);
}

print(render("catalog", 3));
