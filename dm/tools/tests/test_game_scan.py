"""The game file's health scan (dm/host/game_scan.h, the Mac launcher's "Scan for errors" button, dm/mac/Launcher.swift GameFileSection): a NUP whose .zs files are damaged inside a
valid container names them — one damaged file stored raw, one under the packer's own zstd (the damaged Ocarina of Time textures were both: 12,288 zero bytes where the zstd frame
should start) — and a healthy container passes with its checked counts. The harness is compiled here as pack_app.py's build_launcher compiles the launcher (arm64, Homebrew's static
zstd; without it the scan leaves the files stored compressed unchecked). No game files or keys needed."""
import platform
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/tools'))
sys.path.insert(0, str(REPO / 'dm/tools/tests'))
import romfs_image
sys.path.insert(0, str(REPO / 'scripts'))
import pack_nup
from test_nsp_nup import META, TID, VER, npdm, write_nup

ZSTD_BAD = b'\0' * 12288   # what a damaged .zs holds: zeros where its zstd frame should start
ZSTD_GOOD = pack_nup.zstd.compress(b'zstd frame payload' * 40)
RAW_HEAD = b'\x28\xb5\x2f\xfd' + b'rest of a zstd frame'   # a small .zs stored raw: the frame magic is its own first bytes

HARNESS = r'''
#include "nup_image.h"
#include "game_scan.h"
int main(int argc, char **argv) {
    char why[1024] = ""; uint32_t got = 0;
    romfs_img *m;
    if (nup_is(argv[1])) {
        if (!(m = nup_image_open(argv[1], (uint32_t)strtoul(argv[2], NULL, 10), &got, why, sizeof why))) { fprintf(stderr, "%s\n", why); return 2; }
    } else if (!(m = romfs_image_open(argv[1]))) { perror("romfs_image_open"); return 2; }
    dm_scan_report r; memset(&r, 0, sizeof r);
    dm_game_scan(m, &r);
    romfs_image_close(m);
    printf("files=%llu checked=%llu damaged=%llu packed=%llu zstd=%llu zstd_ok=%d more=%llu truncated=%d\n",
           (unsigned long long)r.files, (unsigned long long)r.checked, (unsigned long long)r.damaged,
           (unsigned long long)r.packed_damaged, (unsigned long long)r.zstd_files, r.zstd_ok, (unsigned long long)r.more, r.truncated);
    fputs(r.list, stdout);
    return 0;
}
'''


def build_harness(out):
    zstd = subprocess.run(['brew', '--prefix', 'zstd'], capture_output=True, text=True)
    flags, lib = [], []
    if zstd.returncode == 0 and (Path(zstd.stdout.strip()) / 'lib/libzstd.a').is_file():
        pre = Path(zstd.stdout.strip())
        flags, lib = ['-DDM_HAVE_NUP=1', '-I', str(pre / 'include')], [str(pre / 'lib/libzstd.a')]
    sdk = subprocess.run(['xcrun', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
    src = Path(out) / 'harness.c'
    src.write_text(HARNESS)
    subprocess.run(['clang', '-isysroot', sdk, '-arch', 'arm64', '-O2', '-Wall', '-Werror', '-I', str(REPO / 'dm/host'), *flags,
                    '-o', str(out / 'harness'), str(src), str(REPO / 'dm/host/save_sync.c'), *lib], check=True)
    return out / 'harness'


def scan(harness, path, version=0):
    r = subprocess.run([str(harness), str(path), str(version)], capture_output=True, text=True, check=True)
    first, *lines = r.stdout.splitlines()
    d = dict(kv.split('=') for kv in first.split())
    return {k: int(v) for k, v in d.items()}, [ln for ln in lines if ln]


class GameScanTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if platform.machine() != 'arm64' or sys.platform != 'darwin':
            raise unittest.SkipTest('the scan harness builds for an arm64 Mac')
        cls.dir = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.dir.cleanup)
        cls.harness = build_harness(Path(cls.dir.name))

    def nup(self, tree):
        path = Path(self.dir.name) / f'{abs(hash(tuple(sorted(tree))))}.nup'
        write_nup(path, [(1, TID, VER, {'exefs': {'main': b'code', 'main.npdm': npdm(TID)}, 'romfs': tree}, META)])
        self.addCleanup(path.unlink)
        return path

    def test_healthy(self):
        d, list_ = scan(self.harness, self.nup({
            'Tex/Good.bntx.zs': ZSTD_GOOD,            # 740 bytes: the fixture stores it as its own zstd frame, whose content starts as a .zs should
            'Tex/Small.zs': RAW_HEAD,                 # 26 bytes: stored raw, its head is the frame magic
            'Tex/NotShader.bntx': b'\0' * 300,        # no suffix promising a format: zeros are fine, not checked
            'Tex/empty.zs': b'',                      # an empty file promises nothing
        }), VER)
        self.assertEqual(d['damaged'], 0)
        self.assertEqual(list_, [])
        self.assertEqual(d['checked'], 2)
        self.assertEqual(d['files'], 3)
        self.assertEqual(d['zstd'], 1)
        self.assertEqual(d['zstd_ok'], 1)

    def test_damaged_raw_and_stored(self):
        d, list_ = scan(self.harness, self.nup({
            'Tex/Raw_Damaged.bntx.zs': ZSTD_BAD[:10],        # stored raw (< 200 bytes): the head itself is zeros
            'Tex/Stored_Damaged.bntx.zs': ZSTD_BAD,          # the fixture's zstd over the damage: the scan inflates the frame, then reads zeros
            'Tex/Good.bntx.zs': ZSTD_GOOD,
        }), VER)
        self.assertEqual(d['damaged'], 2)
        self.assertEqual(d['more'], 0)
        self.assertEqual([ln.split(' (')[0] for ln in list_], ['Tex/Raw_Damaged.bntx.zs', 'Tex/Stored_Damaged.bntx.zs'])
        self.assertTrue(all('starts 00000000' in ln for ln in list_))
        self.assertEqual(d['checked'], 1)

    def test_a_frame_that_does_not_decompress(self):
        path = self.nup({'Tex/Big.bntx': b'payload' * 100})   # 700 bytes: the fixture stores it under its own zstd frame
        blob = pack_nup.zstd.compress(b'payload' * 100)       # the stored bytes, as write_nup compressed them
        b = bytearray(path.read_bytes())
        at = b.find(blob)
        self.assertGreater(at, 0)
        b[at + 20:at + 26] = b'\xde\xad\xbe\xef\xde\xad'      # the container's frame damaged mid-stream (its TOC checks only itself)
        path.write_bytes(b)
        d, list_ = scan(self.harness, path, VER)
        self.assertEqual(d['damaged'], 1)
        self.assertIn('does not decompress', list_[0])

    def test_verdicts(self):
        d, _ = scan(self.harness, self.nup({'Tex/Good.bntx.zs': ZSTD_GOOD}), VER)
        self.assertEqual(d['damaged'], 0)   # 1 healthy: the launcher's modal takes it from damaged and packed_damaged alone
        d, _ = scan(self.harness, self.nup({'Tex/Bad.bntx.zs': ZSTD_BAD[:10]}), VER)
        self.assertEqual(d['damaged'], 1)   # 0 damaged: a good copy of the game file is the fix


if __name__ == '__main__':
    unittest.main()
