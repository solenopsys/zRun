/* Execution-only reference: compile before timing, fresh context per sample.
 * Build against the local QuickJS checkout; see knolage/VM_2026-10-09.md. */
#define _POSIX_C_SOURCE 200809L
#include "quickjs.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static JSValue discard(JSContext *ctx, JSValueConst self, int argc,
                       JSValueConst *argv) {
    (void)ctx; (void)self; (void)argc; (void)argv;
    return JS_UNDEFINED;
}

static uint64_t now(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) abort();
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    FILE *file = fopen(argv[1], "rb");
    if (!file || fseek(file, 0, SEEK_END)) return 2;
    long length = ftell(file);
    if (length < 0 || fseek(file, 0, SEEK_SET)) return 2;
    char *source = malloc((size_t)length + 1);
    if (!source || fread(source, 1, length, file) != (size_t)length) return 2;
    fclose(file);
    source[length] = 0;
    for (int i = 0; i < 9; ++i) {
        JSRuntime *rt = JS_NewRuntime();
        if (!rt) return 2;
        JSContext *ctx = JS_NewContext(rt);
        if (!ctx) return 2;
        JSValue global = JS_GetGlobalObject(ctx);
        if (JS_SetPropertyStr(ctx, global, "print",
                              JS_NewCFunction(ctx, discard, "print", 1)) < 0)
            return 2;
        JS_FreeValue(ctx, global);
        JSValue code = JS_Eval(ctx, source, length, argv[1],
                              JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
        if (JS_IsException(code)) return 1;
        uint64_t start = now();
        JSValue result = JS_EvalFunction(ctx, code);
        uint64_t elapsed = now() - start;
        if (JS_IsException(result)) {
            JSValue exception = JS_GetException(ctx);
            const char *message = JS_ToCString(ctx, exception);
            fprintf(stderr, "%s\n", message ? message : "exception");
            JS_FreeCString(ctx, message);
            JS_FreeValue(ctx, exception);
            return 1;
        }
        if (i >= 2) printf("%" PRIu64 "\n", elapsed);
        JS_FreeValue(ctx, result);
        JS_FreeContext(ctx);
        JS_FreeRuntime(rt);
    }
    free(source);
    return 0;
}
