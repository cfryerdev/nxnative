// The game file's health scan (the Mac launcher's "Scan for errors" button, dm/mac/Launcher.swift GameFileSection, run by dm_game_file_scan in dm/mac/launcher.c): the damage a start
// would not report until the game asked for the file. The index itself is validated at mount (nup_image.h, romfs_image.h); what no start sees is a file whose bytes do not start as its
// name promises — a .zs texture that is no zstd stream. The game asks for such a file again on every pass of its background loader and never gives up: several CPU cores stay busy for
// the whole session and the frame rate sags (docs/reference/packing.md, A damaged file in a NUP or a dump has no hash to fail, PR #1530). A file stored as a zstd frame is inflated and
// its content checked, so a frame that does not decompress whole is damage too. This is not a full verify: file bytes are not hashed against the container's own hashes (a NUP of
// Ocarina of Time: 23.5 GB, about 90 s single-threaded) — and a file packed damaged passes them anyway, as those three textures do.
#pragma once
#include "romfs_image.h"
#if DM_HAVE_NUP
#include <zstd.h>
#endif
#include <stdio.h>

// dm/tools/romfs_image.py's FORMAT_HEADS, the same table: a suffix, and the (bytes, mask) pairs its files' first 4 bytes must match one of (.zs: a zstd frame, or a skippable frame)
static const struct { const char *sfx; uint8_t want[2][4], mask[2][4]; int npairs; } dm_heads[] = {
    { ".zs", {{0x28, 0xB5, 0x2F, 0xFD}, {0x50, 0x2A, 0x4D, 0x18}}, {{0xFF, 0xFF, 0xFF, 0xFF}, {0xF0, 0xFF, 0xFF, 0xFF}}, 2 },
};

#define DM_SCAN_DEPTH 128   // path components the walk follows; a game tree is a handful deep, so deeper is a malformed container

typedef struct {
    uint64_t files, checked, damaged;   // non-empty files in the game file; those whose format could be checked; those that fail the check
    uint64_t packed_damaged;            // files the packer wrote as read because their hashes failed (IMG_ENT_DAMAGED: an image packed --allow-damaged; a NUP mount has none)
    uint64_t zstd_files;                // files stored as zstd frames
    int zstd_ok;                        // those frames were inflated for the check (this app was built with zstd); 0: they were left out
    int truncated;                      // the walk met a path deeper than DM_SCAN_DEPTH or longer than the buffers, so not every file was checked
    uint64_t more;                      // damaged files past the list's room
    size_t used;                        // bytes used of list
    char list[4096];                    // the damaged files, one per line: "Tex/X.bntx.zs (216015 bytes, starts 00000000)"
} dm_scan_report;

// 1 when the file's bytes are fine (or no suffix promises a format to check, *hits then 0), 0 when they are damaged
static int dm_head_matches(const char *name, size_t nlen, const uint8_t *head, size_t got, int *hits) {
    for (size_t t = 0; t < sizeof dm_heads / sizeof *dm_heads; t++) {
        const char *sfx = dm_heads[t].sfx;
        size_t sl = strlen(sfx);
        if (sl > nlen || strncasecmp(name + nlen - sl, sfx, sl)) continue;
        *hits = 1;
        if (got < 4) return 0;   // shorter than any format's start: not what its name promises (romfs_image.py format_mismatches reads the same way)
        for (int p = 0; p < dm_heads[t].npairs; p++) {
            int ok = 1;
            for (int i = 0; i < 4; i++) if ((head[i] & dm_heads[t].mask[p][i]) != (dm_heads[t].want[p][i] & dm_heads[t].mask[p][i])) ok = 0;
            if (ok) return 1;
        }
        return 0;
    }
    return 1;
}

static void dm_scan_note(dm_scan_report *r, const char *path, size_t len, const img_ent *x, const char *what) {
    r->damaged++;
    if (r->truncated) return;
    char line[4352];
    int n = snprintf(line, sizeof line, "%.*s (%llu bytes, %s)", (int)len, path, (unsigned long long)x->b, what);
    if (n < 0) return;
    size_t need = (size_t)n + (r->used ? 1 : 0) + 1;
    if (r->used + need > sizeof r->list) { r->more++; return; }   // the list is full: the rest is named only as a count
    if (r->used) r->list[r->used++] = '\n';
    memcpy(r->list + r->used, line, (size_t)n + 1);
    r->used += (size_t)n;
}

static void dm_scan_entry(const romfs_img *m, uint64_t k, const char *path, size_t len, dm_scan_report *r) {
    const img_ent *x = &m->e[k];
    if (!x->b) return;   // an empty file promises nothing (romfs_image.py format_mismatches leaves it out too)
    r->files++;
    if (x->flags & IMG_ENT_DAMAGED) r->packed_damaged++;
    if (x->flags & IMG_ENT_ZSTD) {
        r->zstd_files++;
        #if DM_HAVE_NUP
        uint64_t csz = m->zext[k];
        uint8_t *in = malloc(csz), *out = malloc(x->b);
        if (!in || !out) { free(in); free(out); dm_scan_note(r, path, len, x, "out of memory while checking"); return; }
        size_t z = romfs_image_read(m->fd, in, csz, (off_t)x->a) ? ZSTD_decompress(out, x->b, in, csz) : (size_t)-1;
        free(in);
        if (ZSTD_isError(z) || z != x->b) {
            char what[128];
            snprintf(what, sizeof what, "does not decompress (%s)", z == (size_t)-1 ? "cannot be read" : ZSTD_isError(z) ? ZSTD_getErrorName(z) : "short");
            dm_scan_note(r, path, len, x, what);
            free(out); return;
        }
        int hits = 0;
        size_t got = x->b < 4 ? (size_t)x->b : 4;
        if (dm_head_matches(m->names + x->name, x->nlen, out, got, &hits)) r->checked += (uint64_t)hits;
        else {
            uint8_t head[4] = {0};
            memcpy(head, out, got);
            char what[32];
            snprintf(what, sizeof what, "starts %02x%02x%02x%02x", head[0], head[1], head[2], head[3]);
            dm_scan_note(r, path, len, x, what);
        }
        free(out);
        #endif   // without zstd the frame is counted (zstd_files) but not checked; the modal says so
        return;
    }
    uint8_t head[4] = {0};
    size_t got = x->b < 4 ? (size_t)x->b : 4;
    if (!romfs_image_read(m->fd, head, got, (off_t)x->a)) { dm_scan_note(r, path, len, x, "cannot be read"); return; }
    char what[32];
    snprintf(what, sizeof what, "starts %02x%02x%02x%02x", head[0], head[1], head[2], head[3]);
    int hits = 0;
    if (dm_head_matches(m->names + x->name, x->nlen, head, got, &hits)) r->checked += (uint64_t)hits;
    else dm_scan_note(r, path, len, x, what);
}

static void dm_scan_dir(const romfs_img *m, uint64_t d, char *path, size_t len, int depth, dm_scan_report *r) {
    if (depth > DM_SCAN_DEPTH) { r->truncated = 1; return; }
    const img_ent *dir = &m->e[d];
    for (uint64_t j = 0; j < dir->b; j++) {
        uint64_t k = dir->a + j;
        const img_ent *x = &m->e[k];
        size_t l2 = len + (len ? 1 : 0) + x->nlen;
        if (l2 >= 4096) { r->truncated = 1; return; }
        if (len) path[len] = '/';
        memcpy(path + len + (len ? 1 : 0), m->names + x->name, x->nlen);
        path[l2] = 0;
        if (x->type) dm_scan_entry(m, k, path, l2, r);   // type 1: a file (a = its offset); type 0: a directory (a = its first child) — romfs_image.h
        else dm_scan_dir(m, k, path, l2, depth + 1, r);
    }
}

// The whole game file. r must be zeroed. The verdict is the caller's: damaged and packed_damaged both 0 is healthy, else the file needs a good copy
static void dm_game_scan(romfs_img *m, dm_scan_report *r) {
    r->zstd_ok =
        #if DM_HAVE_NUP
        1;
        #else
        0;
        #endif
    char path[4096];
    dm_scan_dir(m, 0, path, 0, 0, r);
}
