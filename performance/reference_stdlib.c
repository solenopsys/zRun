#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

#define main zmqjs_bench_unused_cli_main
#include "mqjs.c"
#undef main

const JSSTDLibraryDef *zmqjs_bench_stdlib(void) {
    return &js_stdlib;
}

JSContext *zmqjs_bench_new_compile_context(void *memory, size_t size) {
    return JS_NewContext2(memory, size, &js_stdlib, TRUE);
}

JSValue zmqjs_bench_parse(JSContext *ctx, const char *source, size_t length) {
    return JS_Parse(ctx, source, length, "compile-bench.js", 0);
}

static void discard_output(void *opaque, const void *buffer, size_t length) {
    (void)opaque;
    (void)buffer;
    (void)length;
}

void zmqjs_bench_suppress_output(JSContext *ctx) {
    JS_SetLogFunc(ctx, discard_output);
}

int zmqjs_bench_is_exception(JSValue value) {
    return JS_IsException(value);
}

int zmqjs_bench_redirect_stdout(void) {
    const int null_fd = open("/dev/null", O_WRONLY);
    if (null_fd < 0) return -1;
    fflush(stdout);
    const int result = dup2(null_fd, STDOUT_FILENO);
    close(null_fd);
    return result < 0 ? -1 : 0;
}
