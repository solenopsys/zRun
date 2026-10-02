// Nullish coalescing, optional access and ??= lowered to guarded loads/branches.
var checksum = 0, absent = null, present = {value: 3};
for (var run = 0; run < 100000; run++) {
    var selected = present === null ? 0 : present.value;
    var optional = absent === null ? 0 : absent.value;
    var assigned = run & 1 ? null : 5;
    if (assigned === null) assigned = 7;
    checksum += selected + optional + assigned;
}
if (checksum !== 900000) throw "lowered optional checksum";
print("PASS nullish benchmark");
