function withoutId(__zrun_arg) {
	var id = __zrun_arg.id;
	var event = {};
	for (var key of Object.keys(__zrun_arg)) {
		if (key !== "id") event[key] = __zrun_arg[key];
	}
	return event;
}

var event = withoutId({ id: 7, type: "created", count: 3 });
if (event.id !== undefined || event.type !== "created" || event.count !== 3) {
	throw "lowered object rest mismatch";
}
print("PASS parameter.object-rest-lowered");
print("FIXTURE_DONE object_rest_lowered");
