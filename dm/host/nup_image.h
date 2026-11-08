// A NUP container (https://github.com/a55uka/nup, SPEC v1; scripts/pack_nup.py reads the same layout) mounted as the game's RomFS: nup_image_open builds, for the RomFS of one
// package, the index romfs_image_open reads from a DMROMFS1 image (romfs_image.h), so the host reads the game straight from the .nup the player chose in the Mac launcher (Game file),
// with no RomFS.img made from it. A file the container stores raw is read at its extent, as an image's file is; one stored as a zstd frame is flagged IMG_ENT_ZSTD, with its extent's
// size in zext[], and hle_fs.c decompresses it at its first read. The TOC's SHA-256 is checked; the files' are not (that would read the whole container at every start)
#pragma once
#include "romfs_image.h"
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>

#define IMG_ENT_ZSTD 4   // in memory only, on a NUP mount: the file is one zstd frame; a = its extent's offset, b = its size uncompressed, zext[k] = its extent's size
#define NUP_NO_DIR 0xFFFFFFFFu

typedef struct __attribute__((packed)) { char magic[4]; uint16_t hsize, r0; uint64_t toc_off, toc_size; uint8_t toc_sha[32]; uint64_t blob, fsize; uint32_t npkg, flags; uint8_t uuid[16], r1[32]; } nup_super;
typedef struct __attribute__((packed)) { char magic[4]; uint32_t npkg; uint64_t ndirs, nfiles, pool_off, pool_size, r0; } nup_toc;
typedef struct __attribute__((packed)) { uint64_t title_id; uint32_t root, exefs, romfs, version; uint8_t kind, flags; uint16_t r1; uint32_t r2; uint64_t meta_off; uint32_t meta_size; uint8_t pad[20]; } nup_pkg;
typedef struct __attribute__((packed)) { uint32_t name, nlen, first, count; uint64_t r0; } nup_dir;
typedef struct __attribute__((packed)) { uint32_t name, nlen; uint64_t size, eoff, esz; uint8_t sha[32]; uint8_t codec, cflags; uint16_t r0; uint8_t pad[12]; } nup_file;
_Static_assert(sizeof(nup_super) == 0x80 && sizeof(nup_toc) == 0x30 && sizeof(nup_pkg) == 0x40 && sizeof(nup_dir) == 0x18 && sizeof(nup_file) == 0x50, "NUP record layout");

static int nup_is(const char *path) {   // whether the file at path starts as a NUP does
    int fd = open(path, O_RDONLY); char m[4]; if (fd < 0) return 0;
    int is = romfs_image_read(fd, m, 4, 0) && !memcmp(m, "NUP", 3); close(fd); return is;
}

typedef struct { const char *name; uint32_t nlen, slot; } nup_child;
static int nup_child_cmp(const void *a, const void *b) {   // by name bytes, a shorter prefix first: the order img_find's binary search needs
    const nup_child *x = a, *y = b; int c = memcmp(x->name, y->name, x->nlen < y->nlen ? x->nlen : y->nlen);
    return c ? c : (x->nlen > y->nlen) - (x->nlen < y->nlen);
}

// The RomFS of the package of version want (0: the newest update, else the base game). NULL with a reason in why on failure; *version gets the package's version
static romfs_img *nup_image_open(const char *path, uint32_t want, uint32_t *version, char *why, size_t whyn) {
    int fd = open(path, O_RDONLY); struct stat st; nup_super s; uint8_t *toc = NULL, sha[32];
    img_ent *e = NULL; char *pool = NULL; uint64_t *zext = NULL; nup_child *kids = NULL; uint32_t *src = NULL; romfs_img *m = NULL;
    #define NUP_FAIL(...) do { snprintf(why, whyn, __VA_ARGS__); goto bad; } while (0)
    if (fd < 0) NUP_FAIL("%s cannot be opened (%s)", path, strerror(errno));
    if (fstat(fd, &st) || !romfs_image_read(fd, &s, sizeof s, 0)) NUP_FAIL("%s cannot be read", path);
    if (memcmp(s.magic, "NUP", 3)) NUP_FAIL("%s is not a NUP file", path);
    if (s.magic[3] != 1) NUP_FAIL("%s is a NUP of format version %d; this app reads version 1", path, s.magic[3]);
    if (s.fsize != (uint64_t)st.st_size) NUP_FAIL("%s is %lld bytes, its header says %llu: copied or downloaded only in part", path, (long long)st.st_size, (unsigned long long)s.fsize);
    if (s.hsize < sizeof s || s.toc_off != s.hsize || s.flags || s.toc_size < sizeof(nup_toc) || s.toc_size > (512u << 20) || s.toc_off + s.toc_size > s.blob || s.blob > s.fsize)
        NUP_FAIL("%s has an unsupported or damaged header", path);
    if (!(toc = malloc(s.toc_size)) || !romfs_image_read(fd, toc, s.toc_size, (off_t)s.toc_off)) NUP_FAIL("%s: its table of contents cannot be read", path);
    CC_SHA256(toc, (CC_LONG)s.toc_size, sha);
    if (memcmp(sha, s.toc_sha, 32)) NUP_FAIL("%s: its table of contents does not match its SHA-256 (a damaged file)", path);
    const nup_toc *t = (const nup_toc *)toc;
    uint64_t need = sizeof *t + (uint64_t)t->npkg * sizeof(nup_pkg) + t->ndirs * sizeof(nup_dir) + t->nfiles * sizeof(nup_file);
    if (memcmp(t->magic, "TOC\x01", 4) || t->npkg != s.npkg || !t->npkg || need > s.toc_size || t->pool_off < need || t->pool_off + t->pool_size > s.toc_size || (t->pool_off - need) % 4 || t->ndirs + t->nfiles > UINT32_MAX)
        NUP_FAIL("%s: malformed table of contents", path);
    const nup_pkg *pk = (const nup_pkg *)(toc + sizeof *t); const nup_dir *dirs = (const nup_dir *)(pk + t->npkg); const nup_file *files = (const nup_file *)(dirs + t->ndirs);
    const uint32_t *slots = (const uint32_t *)(files + t->nfiles); uint64_t nslots = (t->pool_off - need) / 4; const char *names = (const char *)toc + t->pool_off;
    const nup_pkg *k = NULL, *base = NULL;
    for (uint32_t i = 0; i < t->npkg; i++) {
        if (pk[i].kind == 0 && !base) base = &pk[i];
        if (pk[i].kind > 1) continue;   // add-on content: not the game's RomFS
        if (want ? pk[i].version == want : (!k || pk[i].version > k->version)) k = &pk[i];
    }
    if (!k) {
        char list[256] = ""; size_t o = 0;
        for (uint32_t i = 0; i < t->npkg && o < sizeof list - 16; i++) if (pk[i].kind <= 1) o += (size_t)snprintf(list + o, sizeof list - o, "%s%u", o ? ", " : "", pk[i].version);
        NUP_FAIL("%s holds no version %u, the version this app was built for (it holds: %s)", path, want, *list ? list : "none");
    }
    uint32_t d0 = k->romfs != NUP_NO_DIR ? k->romfs : base ? base->romfs : NUP_NO_DIR;
    if (d0 == NUP_NO_DIR || d0 >= t->ndirs) NUP_FAIL("%s: version %u has no romfs/ (nor a base game with one)", path, k->version);
    if (version) *version = k->version;
    // Breadth-first: entry 0 is the RomFS root; a directory's children are one run of entries, sorted by name, numbered as the directories before it are expanded
    uint64_t cap = 1 << 16, n = 1, pcap = 1 << 22, plen = 0, kcap = 1024;
    if (!(e = calloc(cap, sizeof *e)) || !(src = calloc(cap, sizeof *src)) || !(zext = calloc(cap, sizeof *zext)) || !(pool = malloc(pcap)) || !(kids = malloc(kcap * sizeof *kids))) NUP_FAIL("out of memory");
    src[0] = d0;
    for (uint64_t x = 0; x < n; x++) {
        if (e[x].type) continue;
        const nup_dir *d = &dirs[src[x]];
        if ((uint64_t)d->first + d->count > nslots) NUP_FAIL("%s: a folder runs past the table of contents", path);
        uint32_t c = 0;
        if (d->count > kcap) { kcap = d->count; free(kids); if (!(kids = malloc(kcap * sizeof *kids))) NUP_FAIL("out of memory"); }
        for (uint32_t j = 0; j < d->count; j++) {
            uint32_t sl = slots[d->first + j]; uint32_t no, nl;
            if (sl < t->ndirs) { no = dirs[sl].name; nl = dirs[sl].nlen; }
            else if (sl - t->ndirs < t->nfiles) { no = files[sl - t->ndirs].name; nl = files[sl - t->ndirs].nlen; }
            else NUP_FAIL("%s: a folder's child is out of bounds", path);
            if ((uint64_t)no + nl > t->pool_size || !nl || nl > 0x300 || memchr(names + no, 0, nl) || memchr(names + no, '/', nl)) NUP_FAIL("%s: a bad name in the table of contents", path);
            if (sl >= t->ndirs && nl == 8 && !memcmp(names + no, ".listing", 8)) continue;   // a dump tool's artifact (SPEC 6.3): not a game file
            kids[c++] = (nup_child){names + no, nl, sl};
        }
        qsort(kids, c, sizeof *kids, nup_child_cmp);
        for (uint32_t j = 1; j < c; j++) if (!nup_child_cmp(&kids[j - 1], &kids[j])) NUP_FAIL("%s: a folder names one child twice", path);
        e[x].a = n; e[x].b = c;
        if (n + c > cap) {
            while (n + c > cap) cap *= 2;
            img_ent *e2 = realloc(e, cap * sizeof *e); if (!e2) NUP_FAIL("out of memory"); e = e2;
            uint32_t *s2 = realloc(src, cap * sizeof *src); if (!s2) NUP_FAIL("out of memory"); src = s2;
            uint64_t *z2 = realloc(zext, cap * sizeof *zext); if (!z2) NUP_FAIL("out of memory"); zext = z2;
        }
        for (uint32_t j = 0; j < c; j++, n++) {
            if (plen + kids[j].nlen > pcap) { while (plen + kids[j].nlen > pcap) pcap *= 2; char *p2 = realloc(pool, pcap); if (!p2) NUP_FAIL("out of memory"); pool = p2; }
            memcpy(pool + plen, kids[j].name, kids[j].nlen);
            img_ent *y = &e[n]; memset(y, 0, sizeof *y); zext[n] = 0;
            y->name = (uint32_t)plen; y->nlen = (uint16_t)kids[j].nlen; plen += kids[j].nlen;
            if (kids[j].slot < t->ndirs) { y->type = 0; src[n] = kids[j].slot; }
            else {
                const nup_file *f = &files[kids[j].slot - t->ndirs];
                if (f->codec > 1 || f->cflags) NUP_FAIL("%s: a file uses compression %u, which this app does not read", path, f->codec);
                if (f->size && (f->eoff < s.blob || f->eoff + f->esz > s.fsize || !f->esz || (!f->codec && f->esz != f->size))) NUP_FAIL("%s: a file runs past the container", path);
                y->type = 1; y->a = f->size ? f->eoff : 0; y->b = f->size; src[n] = 0;
                if (f->codec == 1 && f->size) { y->flags = IMG_ENT_ZSTD; zext[n] = f->esz; }
            }
        }
    }
    // One block as an image's index is: the entries, then the names
    img_ent *blk = malloc(n * sizeof *e + plen + 1); if (!blk) NUP_FAIL("out of memory");
    memcpy(blk, e, n * sizeof *e); memcpy((char *)blk + n * sizeof *e, pool, plen);
    if (!(m = calloc(1, sizeof *m))) { free(blk); NUP_FAIL("out of memory"); }
    m->fd = fd; m->n = n; m->e = blk; m->names = (const char *)blk + n * sizeof *e; m->zext = zext; zext = NULL;
    free(e); free(src); free(pool); free(kids); free(toc);
    return m;
bad:
    #undef NUP_FAIL
    if (fd >= 0) close(fd);
    free(e); free(src); free(pool); free(kids); free(toc); free(zext); free(m);
    return NULL;
}
