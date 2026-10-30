// Benchmarks yyjson, generally the fastest C JSON library, which has its own
// RFC 6902 implementation.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "yyjson.h"

static char *slurp(const char *dir, const char *name, const char *suffix, size_t *len) {
    char path[1024];
    snprintf(path, sizeof path, "%s/%s%s", dir, name, suffix);
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END);
    *len = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *data = malloc(*len);
    if (fread(data, 1, *len, f) != *len) exit(1);
    fclose(f);
    return data;
}

static unsigned long long now(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static int compare(const void *a, const void *b) {
    unsigned long long x = *(unsigned long long *)a, y = *(unsigned long long *)b;
    return x < y ? -1 : x > y;
}

int main(int argc, char **argv) {
    const char *dir = argv[1];
    unsigned long long min = strtoull(argv[2], 0, 10) * 1000000ull;
    for (int a = 3; a < argc; a++) {
        const char *name = argv[a];
        size_t doc_len, patch_len, result_len = 0;
        char *doc_text = slurp(dir, name, ".doc.json", &doc_len);
        char *patch_text = slurp(dir, name, ".patch.json", &patch_len);
        size_t cap = 1 << 16, n = 0;
        unsigned long long *times = malloc(cap * sizeof *times);
        char *result = NULL;
        unsigned long long started = now();
        while (n < 5 || now() - started < min) {
            unsigned long long start = now();
            yyjson_doc *doc = yyjson_read(doc_text, doc_len, 0);
            yyjson_doc *patch = yyjson_read(patch_text, patch_len, 0);
            yyjson_mut_doc *out = yyjson_mut_doc_new(NULL);
            yyjson_patch_err err;
            yyjson_mut_val *value = yyjson_patch(out, yyjson_doc_get_root(doc), yyjson_doc_get_root(patch), &err);
            if (!value) { fprintf(stderr, "%s: patch failed at %zu: %s\n", name, err.idx, err.msg); exit(1); }
            free(result);
            result = yyjson_mut_val_write(value, 0, &result_len);
            yyjson_mut_doc_free(out);
            yyjson_doc_free(patch);
            yyjson_doc_free(doc);
            if (n == cap) times = realloc(times, (cap *= 2) * sizeof *times);
            times[n++] = now() - start;
        }
        qsort(times, n, sizeof *times, compare);
        char path[1024];
        snprintf(path, sizeof path, "%s/out/yyjson.%s.json", dir, name);
        FILE *f = fopen(path, "wb");
        fwrite(result, 1, result_len, f);
        fclose(f);
        printf("%s %llu\n", name, times[n / 2]);
    }
    return 0;
}
