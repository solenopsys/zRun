var company = {
	id: "co-7",
	name: "Northwind",
	active: true
};

company.active = false;

var field = "name";
company["region"] = "eu";
print(company.id, company.active, company[field], company.region);
