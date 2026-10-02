if (Number("12") + Number(true) !== 13) throw "Number conversion mismatch";
if (Number(null) !== 0) throw "Number null conversion mismatch";
if (String(Number("3.5")) !== "3.5") throw "Number decimal conversion mismatch";
print("PASS Number conversion");
print("FIXTURE_DONE number_formatting");
