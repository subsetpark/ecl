/* Private, disposable libgit2 worker. No ECL code or checkout is executed.
 * Its parent owns the staging directory and reaps it before removing files.
 * The artifact contract is byte-sorted paths, regular mode 0644, zero owners
 * and times, POSIX pax path records only when needed, and stored gzip blocks.
 */
#include <git2.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

#define MAX_FILES 100000u
#define MAX_BYTES ((uint64_t)1024 * 1024 * 1024)
#define MAX_PATH 4096u
struct entry {
    char *path;
    git_oid oid;
    size_t size;
};
struct tree_export {
    git_repository *repo;
    struct entry *files;
    size_t count;
    uint64_t bytes;
};
static int failure(const char *message) {
    fprintf(stderr, "%.900s\n", message);
    return 1;
}
static int git_failure(const char *operation) {
    const git_error *err = git_error_last();
    fprintf(stderr, "%.100s: %.700s\n", operation, err ? err->message : "Git operation failed");
    return 1;
}
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
    (void)payload;
    return p->received_bytes > MAX_BYTES / 2 || p->total_objects > 200000 ? -1 : 0;
}
static int redirect(git_remote *remote, int direction, void *payload) {
    (void)direction;
    (void)payload;
    return https(git_remote_url(remote)) ? 0 : -1;
}
static int collect(const char *root, const git_tree_entry *item, void *payload) {
    struct tree_export *out = payload;
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
    if (out->count == MAX_FILES)
        return -1;
    git_blob *blob = NULL;
    if (git_blob_lookup(&blob, out->repo, git_tree_entry_id(item)))
        return -1;
    uint64_t size = git_blob_rawsize(blob);
    git_blob_free(blob);
    if (size > MAX_BYTES || out->bytes > MAX_BYTES - size)
        return -1;
    out->bytes += size;
    struct entry *entry = &out->files[out->count];
    entry->path = malloc(strlen(root) + strlen(name) + 1);
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
    FILE *file;
    uint32_t crc;
    uint64_t size;
};
static int raw(struct gzip_writer *w, const void *bytes, size_t size) {
    return fwrite(bytes, 1, size, w->file) == size ? 0 : -1;
}
static int emit(struct gzip_writer *w, const void *bytes, size_t size) {
    const unsigned char *p = bytes;
    if (w->size + size > MAX_BYTES)
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
    FILE *f = fopen("artifact.tgz", "wb");
    if (!f)
        return -1;
    struct gzip_writer w = {f, 0xffffffffu, 0};
    const unsigned char start[10] = {31, 139, 8, 0, 0, 0, 0, 0, 0, 255};
    int status = raw(&w, start, sizeof start);
    int manifest = 0;
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
        if (!strcmp(e->path, "ecl.pkg")) {
            if (e->size > 16 * 1024 * 1024)
                status = -1;
            else {
                FILE *m = fopen("manifest", "wb");
                if (!m)
                    status = -1;
                else {
                    if (fwrite(data, 1, e->size, m) != e->size)
                        status = -1;
                    if (fclose(m))
                        status = -1;
                }
                manifest = 1;
            }
        }
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
    if (fclose(f))
        status = -1;
    return manifest ? status : -1;
}
int ecl_git_helper(const char *url, const char *selector, const char *revision,
                   const char *ca_file) {
    alarm(180);
    struct rlimit file_limit = {MAX_BYTES + MAX_BYTES / 16, MAX_BYTES + MAX_BYTES / 16};
    if (setrlimit(RLIMIT_FSIZE, &file_limit))
        return failure("cannot bound Git storage");
    struct rlimit memory_limit = {3ull * MAX_BYTES, 3ull * MAX_BYTES};
    if (setrlimit(RLIMIT_AS, &memory_limit))
        return failure("cannot bound Git memory");
    if (!https(url) || strlen(url) > 8192 || strlen(revision) > 1024)
        return failure("Git requires an HTTPS URL without credentials and a bounded revision");
    int is_tag = !strcmp(selector, "tag");
    if (!is_tag && strcmp(selector, "commit"))
        return failure("Git requires exactly one tag or full commit selector");
    char ref[1100];
    if (is_tag) {
        snprintf(ref, sizeof ref, "refs/tags/%s", revision);
        int valid = 0;
        if (!*revision || git_reference_name_is_valid(&valid, ref) || !valid)
            return failure("invalid Git tag name");
    } else {
        if (strlen(revision) != 40 || strspn(revision, "0123456789abcdef") != 40)
            return failure("Git requires a full lowercase commit ID");
        strcpy(ref, revision);
    }
    if (git_libgit2_init() < 0)
        return git_failure("initialize Git");
    for (int level = GIT_CONFIG_LEVEL_SYSTEM; level <= GIT_CONFIG_LEVEL_GLOBAL; ++level)
        if (git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH, level, ""))
            return git_failure("isolate Git configuration");
    if (git_libgit2_opts(GIT_OPT_SET_SERVER_CONNECT_TIMEOUT, 10000) ||
        git_libgit2_opts(GIT_OPT_SET_SERVER_TIMEOUT, 30000))
        return git_failure("set Git timeouts");
#ifdef __APPLE__
    if (!*ca_file)
        ca_file = "/etc/ssl/cert.pem";
#endif
    if (*ca_file && git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, ca_file, NULL))
        return git_failure("load Git trust roots");
    git_repository *repo = NULL;
    git_repository_init_options init = GIT_REPOSITORY_INIT_OPTIONS_INIT;
    init.flags =
        GIT_REPOSITORY_INIT_BARE | GIT_REPOSITORY_INIT_NO_REINIT | GIT_REPOSITORY_INIT_MKPATH;
    init.mode = 0700;
    if (git_repository_init_ext(&repo, "repository", &init))
        return git_failure("create bare Git repository");
    git_remote *remote = NULL;
    if (git_remote_create_anonymous(&remote, repo, url))
        return git_failure("create HTTPS remote");
    git_fetch_options fetch = GIT_FETCH_OPTIONS_INIT;
    fetch.download_tags = GIT_REMOTE_DOWNLOAD_TAGS_NONE;
    fetch.depth = 1;
    /* libgit2 refuses HTTPS downgrade redirects; initial-request redirects
     * allow ordinary canonical repository redirects without redirecting POST. */
    fetch.follow_redirects = GIT_REMOTE_REDIRECT_INITIAL;
    fetch.callbacks.transfer_progress = transfer;
    fetch.callbacks.remote_ready = redirect;
    char spec[2200];
    snprintf(spec, sizeof spec, "+%s:refs/ecl/selected", ref);
    char *refs[] = {spec};
    git_strarray refspecs = {refs, 1};
    if (git_remote_fetch(remote, &refspecs, &fetch, NULL))
        return git_failure("fetch pinned Git revision (it may be unavailable)");
    git_object *object = NULL, *commit = NULL;
    if (is_tag) {
        git_reference *reference = NULL;
        if (git_reference_lookup(&reference, repo, "refs/ecl/selected") ||
            git_reference_peel(&object, reference, GIT_OBJECT_ANY))
            return git_failure("resolve Git tag");
        git_reference_free(reference);
        if (git_object_peel(&commit, object, GIT_OBJECT_COMMIT))
            return failure("Git tag does not target a commit");
        git_object_free(object);
    } else {
        git_oid oid;
        if (git_oid_fromstr(&oid, revision) ||
            git_object_lookup(&commit, repo, &oid, GIT_OBJECT_COMMIT))
            return failure("pinned Git commit is unavailable or is not a commit");
    }
    char commit_id[41];
    git_oid_tostr(commit_id, sizeof commit_id, git_object_id(commit));
    FILE *id = fopen("commit", "wb");
    if (!id)
        return failure("cannot record Git commit");
    if (fwrite(commit_id, 1, 40, id) != 40 || fclose(id))
        return failure("cannot record Git commit");
    git_tree *tree = NULL;
    if (git_commit_tree(&tree, (git_commit *)commit))
        return git_failure("read committed Git tree");
    struct tree_export out = {repo, calloc(MAX_FILES, sizeof(struct entry)), 0, 0};
    if (!out.files)
        return failure("Git export allocation failed");
    if (git_tree_walk(tree, GIT_TREEWALK_PRE, collect, &out))
        return failure("Git tree has forbidden entries or exceeds package limits");
    if (export_files(&out))
        return failure(
            "Git export failed: root ecl.pkg required, or artifact exceeds package limits");
    /* The OS reclaims this disposable worker's bounded object graph. */
    return 0;
}
