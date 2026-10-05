var i = 0;
var value = 1;
while (i < 1000000) {
    i++;
    value *= 3;
    value &= 65535;
    value ^= i;
}
print(i, value);
