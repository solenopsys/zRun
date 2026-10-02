if (typeof document == "undefined" && typeof window == "undefined") {
    print("PASS browser globals unavailable");
} else {
    print("FAIL browser globals unavailable");
}
