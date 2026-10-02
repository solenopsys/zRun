var sum = 0;
for (var i = 0; i < 10; i++) {
    if (i === 4) continue;
    if (i === 8) break;
    sum += i;
}
print(sum);
