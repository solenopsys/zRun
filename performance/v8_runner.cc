#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <fstream>
#include <iostream>
#include <iterator>
#include <string>

typedef struct v8_rt v8_rt_t;
extern "C" {
v8_rt_t *v8_rt_new(void);
void v8_rt_free(v8_rt_t *rt);
int v8_rt_load(v8_rt_t *rt, const uint8_t *src, size_t src_len,
               const char *filename, size_t filename_len, uint8_t **out_ptr,
               size_t *out_len);
int v8_rt_call(v8_rt_t *rt, const char *name, size_t name_len,
               const uint8_t *arg, size_t arg_len, uint8_t **out_ptr,
               size_t *out_len);
void v8_free(uint8_t *ptr, size_t len);
}

int main(int argc, char **argv) {
  if (argc != 2) {
    std::cerr << "usage: v8-runner <script.js>\n";
    return 2;
  }

  std::ifstream file(argv[1], std::ios::binary);
  if (!file) {
    std::cerr << "cannot read source: " << argv[1] << '\n';
    return 2;
  }
  std::string source((std::istreambuf_iterator<char>(file)),
                     std::istreambuf_iterator<char>());
  const std::string prelude =
      "globalThis.__benchmarkOutput = '';"
      "function print(value) { globalThis.__benchmarkOutput = String(value); }"
      "function __readBenchmarkOutput() { return globalThis.__benchmarkOutput; }\n";
  source.insert(0, prelude);

  v8_rt_t *rt = v8_rt_new();
  if (rt == nullptr) {
    std::cerr << "v8_rt_new failed\n";
    return 1;
  }

  uint8_t *output = nullptr;
  size_t output_len = 0;
  int rc = v8_rt_load(rt, reinterpret_cast<const uint8_t *>(source.data()),
                      source.size(), argv[1], std::char_traits<char>::length(argv[1]),
                      &output, &output_len);
  if (rc != 0) {
    std::cerr.write(reinterpret_cast<const char *>(output), output_len);
    std::cerr << '\n';
    v8_free(output, output_len);
    v8_rt_free(rt);
    return 1;
  }
  v8_free(output, output_len);

  output = nullptr;
  output_len = 0;
  rc = v8_rt_call(rt, "__readBenchmarkOutput", 21,
                  reinterpret_cast<const uint8_t *>(""), 0, &output,
                  &output_len);
  if (rc != 0) {
    std::cerr.write(reinterpret_cast<const char *>(output), output_len);
    std::cerr << '\n';
    v8_free(output, output_len);
    v8_rt_free(rt);
    return 1;
  }

  std::cout.write(reinterpret_cast<const char *>(output), output_len);
  std::cout << '\n';
  v8_free(output, output_len);
  v8_rt_free(rt);
  return 0;
}
