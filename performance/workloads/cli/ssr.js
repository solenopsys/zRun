function renderItem(id) {
	return "<li data-id=\"" + id + "\">item</li>";
}

var html = "<ul>";
var i = 0;
while (i < 300) {
	html = html + renderItem(i);
	i = i + 1;
}
html = html + "</ul>";
print(html);
