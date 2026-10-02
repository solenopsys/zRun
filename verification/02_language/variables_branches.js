var total = 4;
total = total + 3;

var label;
if (total === 7) {
	label = "seven";
} else {
	label = "other";
}

var selected = total > 5 ? label : "small";
print(total, label, selected);
