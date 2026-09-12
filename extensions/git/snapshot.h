#ifndef ECL_GIT_SNAPSHOT_H
#define ECL_GIT_SNAPSHOT_H
#include <stddef.h>
#include <stdint.h>
/* All pointers are borrowed for the synchronous invocation. The caller must
 * join it before releasing callbacks. No retained interpreter capabilities. */
struct snapshot_request {
    const char *url, *selector, *revision, *ca_file, *scratch;
    uint64_t transfer_bytes, objects, files, export_bytes, memory_bytes, timeout_ms;
};
struct snapshot_callbacks {
    void *context;
    int (*cancelled)(void *);
    int (*write)(void *, const unsigned char *, size_t);
};
/* 0 success; 1 failure; 2 native allocation failure. Cleanup is joined on
 * every return. A failed stream may contain a prefix and must be discarded. */
int git_snapshot(const struct snapshot_request *, const struct snapshot_callbacks *,
                 char commit[41], char error[1024]);
#endif
