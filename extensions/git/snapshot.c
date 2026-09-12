/* HTTPS Git snapshots. This backend knows only repositories and regular files.
 * Native allocations and the scratch tree belong to this joined invocation. */
#include "snapshot.h"
#include <git2.h>
#include <git2/sys/alloc.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MAX_FILES 100000u
#define MAX_BYTES ((uint64_t)1024 * 1024 * 1024)
#define MAX_PATH 4096u
struct request {
    const struct snapshot_request *limits;
    const struct snapshot_callbacks *callbacks;
    uint64_t deadline;
    _Atomic uint64_t memory;
    _Atomic int oom;
};
/* libgit2 configuration and allocator options are library-global. No request
 * may enter the library until the previous request has destroyed its graph. */
static pthread_mutex_t library_mutex = PTHREAD_MUTEX_INITIALIZER;
static struct request *allocation_owner;
union allocation { max_align_t alignment; size_t size; };
static void *budget_alloc(size_t n, const char *file, int line) {
    (void)file; (void)line;
    struct request *r = allocation_owner;
    uint64_t before = atomic_load(&r->memory);
    if (n > SIZE_MAX - sizeof(union allocation)) goto exhausted;
    size_t total = n + sizeof(union allocation);
    do {
        if (total > r->limits->memory_bytes || before > r->limits->memory_bytes - total)
            goto exhausted;
    } while (!atomic_compare_exchange_weak(&r->memory, &before, before + total));
    union allocation *block = malloc(total);
    if (!block) { atomic_fetch_sub(&r->memory, total); goto exhausted; }
    block->size = n;
    return block + 1;
exhausted:
    atomic_store(&r->oom, 1);
    return NULL;
}
static void budget_free(void *p) {
    if (!p) return;
    union allocation *block = (union allocation *)p - 1;
    atomic_fetch_sub(&allocation_owner->memory, block->size + sizeof *block);
    free(block);
}
static void *budget_realloc(void *p, size_t n, const char *file, int line) {
    if (!n) { budget_free(p); return NULL; }
    void *next = budget_alloc(n, file, line);
    if (!next) return NULL;
    if (p) {
        size_t previous = ((union allocation *)p - 1)->size;
        memcpy(next, p, previous < n ? previous : n);
        budget_free(p);
    }
    return next;
}
static uint64_t milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) return UINT64_MAX;
    return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}
static int stopped(struct request *r) {
    return r->callbacks->cancelled(r->callbacks->context) || milliseconds() >= r->deadline;
}
struct entry { char *path; git_oid oid; size_t size; };
struct tree_export {
    git_repository *repo;
    struct request *request;
    struct entry *files;
    size_t count;
    uint64_t bytes;
};
static int https(const char *url) {
    if (strncmp(url, "https://", 8) || !url[8] || url[8] == '/')
        return 0;
    const char *end = url + 8;
    while (*end && *end != '/' && *end != '?') {
        if (*end == '@')
            return 0;
        ++end;
    }
    for (const unsigned char *p = (const unsigned char *)url; *p; ++p)
        if (*p <= 32 || *p == 127 || *p == '\\' || *p == '#')
            return 0;
    return 1;
}
static int transfer(const git_indexer_progress *p, void *payload) {
    struct request *r = payload;
    return stopped(r) || p->received_bytes > r->limits->transfer_bytes ||
        p->total_objects > r->limits->objects ? -1 : 0;
}
static int sideband(const char *text, int length, void *payload) {
    (void)text; (void)length;
    return stopped(payload) ? -1 : 0;
}
static int redirect(git_remote *remote, int direction, void *payload) {
    (void)direction;
    return !stopped(payload) && https(git_remote_url(remote)) ? 0 : -1;
}
static int collect(const char *root, const git_tree_entry *item, void *payload) {
    struct tree_export *out = payload;
    if (stopped(out->request)) return -1;
    const char *name = git_tree_entry_name(item);
    if (!strcmp(name, ".git") || !strcmp(name, ".") || !strcmp(name, "..") || strchr(name, '\\'))
        return -1;
    if (strlen(root) + strlen(name) >= MAX_PATH)
        return -1;
    if (git_tree_entry_type(item) == GIT_OBJECT_TREE)
        return 0;
    git_filemode_t mode = git_tree_entry_filemode(item);
    if (mode != GIT_FILEMODE_BLOB && mode != GIT_FILEMODE_BLOB_EXECUTABLE)
        return -1;
    if (out->count == out->request->limits->files)
        return -1;
    git_blob *blob = NULL;
    if (git_blob_lookup(&blob, out->repo, git_tree_entry_id(item)))
        return -1;
    uint64_t size = git_blob_rawsize(blob);
    git_blob_free(blob);
    if (size > out->request->limits->export_bytes || out->bytes > out->request->limits->export_bytes - size)
        return -1;
    out->bytes += size;
    struct entry *entry = &out->files[out->count];
    entry->path = budget_alloc(strlen(root) + strlen(name) + 1, __FILE__, __LINE__);
    if (!entry->path)
        return -1;
    strcpy(entry->path, root);
    strcat(entry->path, name);
    entry->oid = *git_tree_entry_id(item);
    entry->size = (size_t)size;
    ++out->count;
    return 0;
}
static int compare(const void *a, const void *b) {
    return strcmp(((const struct entry *)a)->path, ((const struct entry *)b)->path);
}
struct gzip_writer {
    struct request *request;
    uint32_t crc;
    uint64_t size;
};
static int raw(struct gzip_writer *w, const void *bytes, size_t size) {
    return stopped(w->request) ? -1 : w->request->callbacks->write(w->request->callbacks->context, bytes, size);
}
static int emit(struct gzip_writer *w, const void *bytes, size_t size) {
    const unsigned char *p = bytes;
    if (size > w->request->limits->export_bytes || w->size > w->request->limits->export_bytes - size)
        return -1;
    while (size) {
        unsigned n = size > 65535 ? 65535 : (unsigned)size;
        unsigned char h[5] = {0, (unsigned char)n, (unsigned char)(n >> 8), (unsigned char)~n,
                              (unsigned char)(~n >> 8)};
        if (raw(w, h, 5) || raw(w, p, n))
            return -1;
        for (unsigned i = 0; i < n; ++i) {
            w->crc ^= p[i];
            for (int bit = 0; bit < 8; ++bit)
                w->crc = (w->crc >> 1) ^ (0xedb88320u & (0u - (w->crc & 1)));
        }
        w->size += n;
        p += n;
        size -= n;
    }
    return 0;
}
static int padding(struct gzip_writer *w, size_t n) {
    static const unsigned char zeros[1024] = {0};
    return n ? emit(w, zeros, n) : 0;
}
static int header(struct gzip_writer *w, const char *name, size_t size, char type) {
    unsigned char h[512] = {0};
    memcpy(h, name, strlen(name));
    snprintf((char *)h + 100, 8, "%07o", 0644);
    snprintf((char *)h + 108, 8, "%07o", 0);
    snprintf((char *)h + 116, 8, "%07o", 0);
    snprintf((char *)h + 124, 12, "%011llo", (unsigned long long)size);
    snprintf((char *)h + 136, 12, "%011o", 0);
    memset(h + 148, ' ', 8);
    h[156] = (unsigned char)type;
    memcpy(h + 257, "ustar\0", 6);
    memcpy(h + 263, "00", 2);
    unsigned sum = 0;
    for (unsigned i = 0; i < 512; ++i)
        sum += h[i];
    snprintf((char *)h + 148, 7, "%06o", sum);
    h[155] = ' ';
    return emit(w, h, sizeof h);
}
static int export_files(struct tree_export *out) {
    struct gzip_writer w = {out->request, 0xffffffffu, 0};
    const unsigned char start[10] = {31, 139, 8, 0, 0, 0, 0, 0, 0, 255};
    int status = raw(&w, start, sizeof start);
    qsort(out->files, out->count, sizeof *out->files, compare);
    for (size_t i = 0; !status && i < out->count; ++i) {
        struct entry *e = &out->files[i];
        if (strlen(e->path) > 100) {
            char record[MAX_PATH + 32];
            size_t len = strlen(e->path) + 8, next;
            do {
                char number[32];
                snprintf(number, sizeof number, "%zu", len);
                next = strlen(number) + strlen(e->path) + 7;
                if (next == len)
                    break;
                len = next;
            } while (1);
            snprintf(record, sizeof record, "%zu path=%s\n", len, e->path);
            if (header(&w, "PaxHeader", len, 'x') || emit(&w, record, len) ||
                padding(&w, (512 - len % 512) % 512)) {
                status = -1;
                break;
            }
        }
        if (header(&w, strlen(e->path) > 100 ? "PaxFile" : e->path, e->size, '0')) {
            status = -1;
            break;
        }
        git_blob *blob = NULL;
        if (git_blob_lookup(&blob, out->repo, &e->oid)) {
            status = -1;
            break;
        }
        const void *data = git_blob_rawcontent(blob);
        if (!status && (emit(&w, data, e->size) || padding(&w, (512 - e->size % 512) % 512)))
            status = -1;
        git_blob_free(blob);
    }
    if (!status)
        status = padding(&w, 1024);
    if (!status) {
        uint32_t crc = ~w.crc, size = (uint32_t)w.size;
        unsigned char end[13] = {1, 0, 0, 255, 255};
        for (int i = 0; i < 4; ++i) {
            end[5 + i] = (unsigned char)(crc >> (8 * i));
            end[9 + i] = (unsigned char)(size >> (8 * i));
        }
        status = raw(&w, end, sizeof end);
    }
    return status;
}

/* Scratch contains only a private bare repository. Descriptor-relative cleanup
 * never follows links and has a fixed depth bound independent of remote paths. */
static int empty_directory(int fd, unsigned depth) {
    if (depth == 32) return -1;
    int copied = dup(fd);
    if (copied < 0) return -1;
    DIR *dir = fdopendir(copied);
    if (!dir) { close(copied); return -1; }
    int status = 0;
    struct dirent *entry;
    errno = 0;
    while ((entry = readdir(dir))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        struct stat st;
        if (fstatat(fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW)) { status = -1; break; }
        if (S_ISDIR(st.st_mode)) {
            int child = openat(fd, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (child < 0) { status = -1; break; }
            int cleared = empty_directory(child, depth + 1);
            close(child);
            if (cleared || unlinkat(fd, entry->d_name, AT_REMOVEDIR)) { status = -1; break; }
        } else if (unlinkat(fd, entry->d_name, 0)) { status = -1; break; }
        errno = 0;
    }
    if (errno) status = -1;
    closedir(dir);
    return status;
}
int git_snapshot(const struct snapshot_request *limits, const struct snapshot_callbacks *callbacks,
                 char commit_id[41], char message[1024]) {
    const char *operation = "validate Git request";
    int status = 1, initialized = 0, scratch_fd = -1, scratch_created = 0;
    git_repository *repo = NULL;
    git_remote *remote = NULL;
    git_object *commit = NULL;
    git_tree *tree = NULL;
    git_reference *reference = NULL;
    struct request request = {limits, callbacks, milliseconds() + limits->timeout_ms, 0, 0};
    struct tree_export out = {NULL, &request, NULL, 0, 0};
    char scratch[MAX_PATH], repository[MAX_PATH], ref[1100], spec[2200];
    message[0] = 0;
    if (!https(limits->url) || strlen(limits->url) > 8192 || strlen(limits->revision) > 1024 ||
        limits->scratch[0] != '/' || strlen(limits->scratch) > MAX_PATH - 64 ||
        !limits->transfer_bytes || limits->transfer_bytes > MAX_BYTES / 2 ||
        !limits->objects || limits->objects > 200000 || !limits->files || limits->files > MAX_FILES ||
        !limits->export_bytes || limits->export_bytes > MAX_BYTES ||
        !limits->memory_bytes || limits->memory_bytes > 3 * MAX_BYTES ||
        !limits->timeout_ms || limits->timeout_ms > 180000) {
        snprintf(message, 1024, "invalid Git snapshot request or limits"); return 1;
    }
    int is_tag = !strcmp(limits->selector, "tag");
    if ((!is_tag && strcmp(limits->selector, "commit")) ||
        (!is_tag && (strlen(limits->revision) != 40 || strspn(limits->revision, "0123456789abcdef") != 40))) {
        snprintf(message, 1024, "expected a tag or full lowercase commit"); return 1;
    }
    while (pthread_mutex_trylock(&library_mutex)) {
        if (stopped(&request)) { snprintf(message, 1024, "Git snapshot cancelled or deadline exceeded"); return 1; }
        const struct timespec pause = {0, 10000000};
        nanosleep(&pause, NULL);
    }
    allocation_owner = &request;
    git_allocator allocator = {budget_alloc, budget_realloc, budget_free};
    if (git_libgit2_opts(GIT_OPT_SET_ALLOCATOR, &allocator)) goto cleanup;
    operation = "initialize Git";
    if (git_libgit2_init() < 0) goto cleanup;
    initialized = 1;
    if (stopped(&request)) goto cleanup;
    if (is_tag) {
        snprintf(ref, sizeof ref, "refs/tags/%s", limits->revision);
        int valid = 0;
        if (!*limits->revision || git_reference_name_is_valid(&valid, ref) || !valid) goto cleanup;
    } else strcpy(ref, limits->revision);
    operation = "configure isolated Git request";
    for (int level = GIT_CONFIG_LEVEL_SYSTEM; level <= GIT_CONFIG_LEVEL_GLOBAL; ++level)
        if (git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH, level, "")) goto cleanup;
    int wait = limits->timeout_ms < 10000 ? (int)limits->timeout_ms : 10000;
    if (git_libgit2_opts(GIT_OPT_SET_SERVER_CONNECT_TIMEOUT, wait) ||
        git_libgit2_opts(GIT_OPT_SET_SERVER_TIMEOUT, wait) ||
        git_libgit2_opts(GIT_OPT_SET_PACK_MAX_OBJECTS, (size_t)limits->objects) ||
        git_libgit2_opts(GIT_OPT_ENABLE_CACHING, 0)) goto cleanup;
    const char *ca_file = limits->ca_file;
#ifdef __APPLE__
    if (!*ca_file) ca_file = "/etc/ssl/cert.pem";
#endif
    if (*ca_file && git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, ca_file, NULL)) goto cleanup;
    operation = "create private Git scratch repository";
    snprintf(scratch, sizeof scratch, "%s/ecl-git-XXXXXX", limits->scratch);
    if (!mkdtemp(scratch)) goto cleanup;
    scratch_created = 1;
    scratch_fd = open(scratch, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (scratch_fd < 0) goto cleanup;
    snprintf(repository, sizeof repository, "%s/repository", scratch);
    git_repository_init_options init;
    if (git_repository_init_options_init(&init, GIT_REPOSITORY_INIT_OPTIONS_VERSION)) goto cleanup;
    init.flags = GIT_REPOSITORY_INIT_BARE | GIT_REPOSITORY_INIT_NO_REINIT | GIT_REPOSITORY_INIT_MKPATH;
    init.mode = 0700;
    if (git_repository_init_ext(&repo, repository, &init) || git_remote_create_anonymous(&remote, repo, limits->url)) goto cleanup;
    git_fetch_options fetch;
    if (git_fetch_options_init(&fetch, GIT_FETCH_OPTIONS_VERSION)) goto cleanup;
    fetch.download_tags = GIT_REMOTE_DOWNLOAD_TAGS_NONE;
    fetch.depth = 1;
    fetch.follow_redirects = GIT_REMOTE_REDIRECT_INITIAL;
    fetch.callbacks.payload = &request;
    fetch.callbacks.transfer_progress = transfer;
    fetch.callbacks.sideband_progress = sideband;
    fetch.callbacks.remote_ready = redirect;
    snprintf(spec, sizeof spec, "+%s:refs/ecl/selected", ref);
    char *refs[] = {spec};
    git_strarray refspecs = {refs, 1};
    operation = "fetch Git revision (it may be unavailable)";
    if (stopped(&request) || git_remote_fetch(remote, &refspecs, &fetch, NULL)) goto cleanup;
    operation = "resolve fetched Git commit";
    if (git_reference_lookup(&reference, repo, "refs/ecl/selected") ||
        git_reference_peel(&commit, reference, GIT_OBJECT_COMMIT)) goto cleanup;
    git_oid_tostr(commit_id, 41, git_object_id(commit));
    if (!is_tag && strcmp(commit_id, limits->revision)) goto cleanup;
    if (git_commit_tree(&tree, (git_commit *)commit)) goto cleanup;
    out.repo = repo;
    out.files = budget_alloc((size_t)limits->files * sizeof *out.files, __FILE__, __LINE__);
    if (!out.files) goto cleanup;
    operation = "inspect Git tree (regular files and export limits required)";
    if (git_tree_walk(tree, GIT_TREEWALK_PRE, collect, &out)) goto cleanup;
    operation = "stream deterministic Git archive";
    if (export_files(&out) || stopped(&request)) goto cleanup;
    status = 0;
cleanup:
    if (status) {
        const git_error *error = initialized ? git_error_last() : NULL;
        snprintf(message, 1024, "%.150s: %.700s", operation,
                 stopped(&request) ? "cancelled or deadline exceeded" :
                 error ? error->message : "Git snapshot failed");
    }
    for (size_t i = 0; i < out.count; ++i) budget_free(out.files[i].path);
    budget_free(out.files);
    git_tree_free(tree);
    git_object_free(commit);
    git_reference_free(reference);
    git_remote_free(remote);
    git_repository_free(repo);
    if (initialized) git_libgit2_shutdown();
    git_libgit2_opts(GIT_OPT_SET_ALLOCATOR, NULL);
    allocation_owner = NULL;
    pthread_mutex_unlock(&library_mutex);
    int cleanup_failed = 0;
    if (scratch_fd >= 0) { cleanup_failed = empty_directory(scratch_fd, 0); close(scratch_fd); }
    if (scratch_created && rmdir(scratch)) cleanup_failed = 1;
    if (cleanup_failed && !status) { snprintf(message, 1024, "Git scratch cleanup failed"); status = 1; }
    return atomic_load(&request.oom) ? 2 : status;
}
