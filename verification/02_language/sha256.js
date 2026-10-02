var digest = __host(JSON.stringify({ op: "sha256", data: "abc" }));
if (digest !== "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") {
    throw "host sha256 mismatch";
}
print("PASS host.sha256");
print("FIXTURE_DONE sha256");
