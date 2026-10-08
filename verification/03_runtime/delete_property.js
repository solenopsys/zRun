var value = { updatedAt: "old", keep: true };
delete value.updatedAt;
if ("updatedAt" in value || value.keep != true) {
    print("FAIL delete property");
} else {
    print("FIXTURE_DONE delete property");
}
