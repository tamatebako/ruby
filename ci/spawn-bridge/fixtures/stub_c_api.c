/* ci/spawn-bridge tfs link-unit TEST DOUBLE (NOT libtfs).
 *
 * The spawn patch consumes the <tebako/fs/c_api.h> surface; the harness
 * links miniruby against this double so the patched process.c runs for
 * real. The double mirrors the c_api contract with a one-mount VFS:
 *
 *   /__tfs__/<rel>  →  $SPAWN_BRIDGE_VFS_ROOT/<rel>     (the "mount")
 *   materialize     →  copy into $SPAWN_BRIDGE_EXEC_CACHE (the twin)
 *   dlmap2file      →  $SPAWN_BRIDGE_SHIM (the dummy preload shim)
 *
 * Compiled twice (run.sh):
 *   -DSPAWN_BRIDGE_PROBE   — carries tebako_fs_exec_dyld_insertion_honored
 *                            (the tebako#1127 ABI's minimal verdict
 *                            double; the real byte-parse is the tfs
 *                            crate's unit-tested surface)
 *   (without the define)   — the pre-probe link unit: the patch's weak
 *                            extern reads NULL and every spawn keeps
 *                            the injection path byte-identical.
 *
 *   -DSPAWN_BRIDGE_PROBE_MAIN adds a verdict CLI: `stub_c_api <path>`
 *   prints the double's verdict beside `codesign -d` ground truth.
 *
 * Fail-open discipline mirrors the real ABI: unreadable, non-Mach-O or
 * unparseable files answer 1 (attempt the injection).
 */

#include <tebako/fs/c_api.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define VFS_PREFIX "/__tfs__/"

static const char *
sb_root(void)
{
    const char *r = getenv("SPAWN_BRIDGE_VFS_ROOT");
    return r != NULL ? r : "/nonexistent-vfs-root";
}

static const char *
sb_cache(void)
{
    const char *r = getenv("SPAWN_BRIDGE_EXEC_CACHE");
    return r != NULL ? r : "/tmp/spawn-bridge-exec-cache";
}

int
tebako_path_is_embedded(const char *path)
{
    return path != NULL && strncmp(path, VFS_PREFIX, strlen(VFS_PREFIX)) == 0;
}

/* The host file backing an embedded path; every other path passes
 * through. Writes into the caller's buffer. */
static const char *
sb_map(const char *path, char *buf, size_t buflen)
{
    if (!tebako_path_is_embedded(path)) return path;
    snprintf(buf, buflen, "%s/%s", sb_root(), path + strlen(VFS_PREFIX));
    return buf;
}

int
tebako_fs_open(const char *path, int flags)
{
    char buf[PATH_MAX];
    return open(sb_map(path, buf, sizeof(buf)), flags, 0666);
}

ssize_t
tebako_fs_read(int fd, void *buf, size_t count)
{
    return read(fd, buf, count);
}

ssize_t
tebako_fs_pread(int fd, void *buf, size_t nbyte, off_t offset)
{
    return pread(fd, buf, nbyte, offset);
}

off_t
tebako_fs_lseek(int fd, off_t offset, int whence)
{
    return lseek(fd, offset, whence);
}

int
tebako_fs_close(int fd)
{
    return close(fd);
}

tebako_dir_t
tebako_fs_opendir(const char *path)
{
    char buf[PATH_MAX];
    return (tebako_dir_t)opendir(sb_map(path, buf, sizeof(buf)));
}

struct tebako_c_dirent *
tebako_fs_readdir(tebako_dir_t dir)
{
    static struct tebako_c_dirent out;
    struct dirent *e = readdir((DIR *)dir);
    if (e == NULL) return NULL;
    snprintf(out.d_name, sizeof(out.d_name), "%s", e->d_name);
    out.d_type = (unsigned char)e->d_type;
    return &out;
}

int
tebako_fs_closedir(tebako_dir_t dir)
{
    return closedir((DIR *)dir);
}

int
tebako_fs_dir_is_embedded(tebako_dir_t dir)
{
    (void)dir;
    return 0;
}

void
tebako_fs_rewinddir(tebako_dir_t dir)
{
    rewinddir((DIR *)dir);
}

long
tebako_fs_telldir(tebako_dir_t dir)
{
    return telldir((DIR *)dir);
}

void
tebako_fs_seekdir(tebako_dir_t dir, long pos)
{
    seekdir((DIR *)dir, pos);
}

int
tebako_fs_stat(const char *path, struct tebako_stat *st)
{
    char buf[PATH_MAX];
    return stat(sb_map(path, buf, sizeof(buf)), (struct stat *)st);
}

int
tebako_fs_fstat(int fd, struct tebako_stat *st)
{
    return fstat(fd, (struct stat *)st);
}

int
tebako_fd_is_embedded(int fd)
{
    (void)fd;
    return 0;
}

int
tebako_get_errno(void)
{
    return errno;
}

/* Materialize to the exec cache: a byte copy (code signatures ride
 * along), mode 0755, the basename as the twin's name. The double does
 * NOT reimplement Rule E4's sibling sweep — that discipline is the
 * tfs crate's, not the patch's surface. */
char *
tebako_fs_exec_materialize(const char *path)
{
    char src[PATH_MAX];
    char dst[PATH_MAX];
    char buf[65536];
    const char *base;
    const char *mapped;
    FILE *in, *out;
    size_t n;
    int saved;

    mapped = sb_map(path, src, sizeof(src));
    base = strrchr(mapped, '/');
    base = base != NULL ? base + 1 : mapped;
    if (mkdir(sb_cache(), 0755) != 0 && errno != EEXIST) return NULL;
    snprintf(dst, sizeof(dst), "%s/%s", sb_cache(), base);
    in = fopen(mapped, "rb");
    if (in == NULL) return NULL;
    out = fopen(dst, "wb");
    if (out == NULL) {
        saved = errno;
        fclose(in);
        errno = saved;
        return NULL;
    }
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
        if (fwrite(buf, 1, n, out) != n) break;
    }
    saved = ferror(in) || ferror(out) ? EIO : 0;
    fclose(in);
    if (fclose(out) != 0 && saved == 0) saved = errno;
    if (saved != 0) {
        errno = saved;
        return NULL;
    }
    if (chmod(dst, 0755) != 0) return NULL;
    return strdup(dst);
}

/* The chdir verb's double: the backing dir already exists host-side —
 * the twin is the mapping itself. */
char *
tebako_fs_exec_materialize_dir(const char *path)
{
    char buf[PATH_MAX];
    return strdup(sb_map(path, buf, sizeof(buf)));
}

char *
tebako_fs_dlmap2file(const char *path)
{
    const char *shim = getenv("SPAWN_BRIDGE_SHIM");
    (void)path;
    return shim != NULL ? strdup(shim) : NULL;
}

char *
tebako_fs_mounts(void)
{
    return strdup("/__tfs__:/__tfs__");
}

char *
tebako_fs_mount_of(const char *path)
{
    return tebako_path_is_embedded(path) ? strdup("/__tfs__") : NULL;
}

int
tebako_fs_spawn_host_permitted(void)
{
    return 1;
}

/* The jail's host guard: no jail exists in the harness — never guarded. */
int
tebako_fs_host_guard(void)
{
    return 0;
}

/* spec 30 §2's spawned-runtime planner, driver-exported in production:
 * no planner in the harness — every spawn passes through (the weak
 * extern's NULL reads identically). */
int
tebako_spawn_runtime_plan(const char *command,
                          const char *args_packed, size_t args_len,
                          char **out_exe,
                          char **out_argv, size_t *out_argv_len,
                          char **out_env, size_t *out_env_len,
                          char **out_error)
{
    (void)command; (void)args_packed; (void)args_len;
    (void)out_exe; (void)out_argv; (void)out_argv_len;
    (void)out_env; (void)out_env_len; (void)out_error;
    return 0;
}

/* The tebako-main surface (main.c's patch): the harness's miniruby is
 * the whole runtime — no boot-time mount dance, the mount point is the
 * one VFS root, and "miniruby" is the honest answer. */
int
tebako_main(int *argc, char ***argv)
{
    (void)argc; (void)argv;
    return 0;
}

const char *
tebako_mount_point(void)
{
    return "/__tfs__";
}

int
tebako_is_running_miniruby(void)
{
    return 1;
}

const char *
tebako_original_pwd(void)
{
    static char cwd[PATH_MAX];
    return getcwd(cwd, sizeof(cwd)) != NULL ? cwd : "/";
}

/* ------------------------------------------------------------------ */
/* The insertion-probe double (tebako#1127's ABI), probe variant only. */
/* ------------------------------------------------------------------ */
#ifdef SPAWN_BRIDGE_PROBE

#include <mach/machine.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>

#define SB_CS_EMBEDDED_SIGNATURE 0xfade0cc0u
#define SB_CS_CODEDIRECTORY      0xfade0c02u
#define SB_CS_ENTITLEMENTS_XML   0xfade7171u
#define SB_CS_ENTITLEMENTS_DER   0xfade7172u
#define SB_CS_RUNTIME            0x00010000u

#define SB_ENTITLEMENT_KEY "com.apple.security.cs.allow-dyld-environment-variables"

static uint32_t
sb_be32(const unsigned char *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

/* The DER entitlement slot is authoritative when present (tebako#1127's
 * rule): the key rides as a UTF8String followed by its BOOLEAN — TRUE
 * is the byte triple 01 01 ff immediately after the key. XML is the
 * legacy fallback: the plist <key>…</key> followed by <true/>. */
static int
sb_entitled(const unsigned char *blob, uint32_t blen,
            const unsigned char *der, uint32_t derlen,
            const unsigned char *xml, uint32_t xmllen)
{
    static const char key[] = SB_ENTITLEMENT_KEY;
    const size_t klen = sizeof(key) - 1;
    uint32_t i;
    (void)blob;
    (void)blen;

    if (der != NULL) {
        for (i = 0; i + klen + 3 <= derlen; i++) {
            if (memcmp(der + i, key, klen) == 0)
                return der[i + klen] == 0x01 && der[i + klen + 1] == 0x01 &&
                       der[i + klen + 2] == 0xff;
        }
        return 0;
    }
    if (xml != NULL) {
        static const char keytag[] = "<key>" SB_ENTITLEMENT_KEY "</key>";
        const size_t ktlen = sizeof(keytag) - 1;
        for (i = 0; i + ktlen <= xmllen; i++) {
            if (memcmp(xml + i, keytag, ktlen) == 0) {
                uint32_t j;
                for (j = i + ktlen; j + 7 <= xmllen && j < i + ktlen + 64; j++) {
                    if (memcmp(xml + j, "<true/>", 7) == 0) return 1;
                }
                return 0;
            }
        }
        return 0;
    }
    return 0;  /* hardened, no entitlement slots at all: stripped */
}

/* The slice verdict; fail-open (1) on every unparseable shape. */
static int
sb_slice_honored(const unsigned char *mh, size_t mlen)
{
    uint32_t magic, ncmds;
    size_t off, hdr;
    uint32_t cs_off = 0, cs_size = 0;
    uint32_t count, i;
    const unsigned char *cs;
    const unsigned char *cdir = NULL, *der = NULL, *xml = NULL;
    uint32_t derlen = 0, xmllen = 0;
    int saw_xml = 0, saw_der = 0;

    if (mlen < 28) return 1;
    magic = (uint32_t)mh[0] | ((uint32_t)mh[1] << 8) |
            ((uint32_t)mh[2] << 16) | ((uint32_t)mh[3] << 24);
    if (magic == MH_MAGIC) {
        hdr = sizeof(struct mach_header);
    }
    else if (magic == MH_MAGIC_64) {
        hdr = sizeof(struct mach_header_64);
    }
    else {
        return 1;  /* big-endian or not Mach-O: not the stripped shape */
    }
    if (mlen < hdr) return 1;
    ncmds = (uint32_t)mh[16] | ((uint32_t)mh[17] << 8) |
            ((uint32_t)mh[18] << 16) | ((uint32_t)mh[19] << 24);
    off = hdr;
    for (i = 0; i < ncmds; i++) {
        uint32_t cmd, cmdsize;
        if (off + 8 > mlen) return 1;
        cmd = (uint32_t)mh[off] | ((uint32_t)mh[off + 1] << 8) |
              ((uint32_t)mh[off + 2] << 16) | ((uint32_t)mh[off + 3] << 24);
        cmdsize = (uint32_t)mh[off + 4] | ((uint32_t)mh[off + 5] << 8) |
                  ((uint32_t)mh[off + 6] << 16) | ((uint32_t)mh[off + 7] << 24);
        if (cmdsize < 8 || off + cmdsize > mlen) return 1;
        if (cmd == LC_CODE_SIGNATURE) {
            cs_off = (uint32_t)mh[off + 8] | ((uint32_t)mh[off + 9] << 8) |
                     ((uint32_t)mh[off + 10] << 16) | ((uint32_t)mh[off + 11] << 24);
            cs_size = (uint32_t)mh[off + 12] | ((uint32_t)mh[off + 13] << 8) |
                      ((uint32_t)mh[off + 14] << 16) | ((uint32_t)mh[off + 15] << 24);
        }
        off += cmdsize;
    }
    if (cs_off == 0 || cs_size == 0) return 1;  /* unsigned: honored */
    cs = mh + cs_off;
    if (cs_size < 12) return 1;
    if (sb_be32(cs) != SB_CS_EMBEDDED_SIGNATURE) return 1;
    count = sb_be32(cs + 8);
    if (12u + count * 8 > cs_size) return 1;
    for (i = 0; i < count; i++) {
        uint32_t type = sb_be32(cs + 12 + i * 8);
        uint32_t boff = sb_be32(cs + 12 + i * 8 + 4);
        if (boff + 8 > cs_size) return 1;
        if (type == 0) {
            cdir = cs + boff;
        }
        else if (type == 5) {
            xml = cs + boff + 8;
            xmllen = sb_be32(cs + boff + 4);
            saw_xml = 1;
        }
        else if (type == 7) {
            der = cs + boff + 8;
            derlen = sb_be32(cs + boff + 4);
            saw_der = 1;
        }
    }
    if (cdir == NULL || sb_be32(cdir) != SB_CS_CODEDIRECTORY) return 1;
    if ((sb_be32(cdir + 12) & SB_CS_RUNTIME) == 0) return 1;  /* not hardened */
    return sb_entitled(cdir, sb_be32(cdir + 4),
                       saw_der ? der : NULL, derlen,
                       saw_xml ? xml : NULL, xmllen);
}

int
tebako_fs_exec_dyld_insertion_honored(const char *path)
{
    unsigned char *data;
    long len;
    FILE *fp;
    int verdict = 1;
    uint32_t magic;
    const unsigned char *slice;

    errno = 0;
    if (path == NULL) {
        errno = EINVAL;
        return 1;
    }
    fp = fopen(path, "rb");
    if (fp == NULL) return 1;
    if (fseek(fp, 0, SEEK_END) != 0 || (len = ftell(fp)) < 0 ||
        fseek(fp, 0, SEEK_SET) != 0) {
        fclose(fp);
        return 1;
    }
    data = (unsigned char *)malloc((size_t)len > 0 ? (size_t)len : 1);
    if (data == NULL) {
        fclose(fp);
        return 1;
    }
    if (len > 0 && fread(data, 1, (size_t)len, fp) != (size_t)len) {
        free(data);
        fclose(fp);
        return 1;
    }
    fclose(fp);

    slice = data;
    magic = len >= 4 ? ((uint32_t)data[0] | ((uint32_t)data[1] << 8) |
                        ((uint32_t)data[2] << 16) | ((uint32_t)data[3] << 24))
                     : 0;
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        /* Pick the host CPU's slice (big-endian arch table). */
        uint32_t narch = sb_be32(data + 4);
        uint32_t i;
        cpu_type_t host =
#if defined(__aarch64__) || defined(__arm64__)
            CPU_TYPE_ARM64;
#else
            CPU_TYPE_X86_64;
#endif
        for (i = 0; i < narch; i++) {
            const unsigned char *arch = data + 8 + i * 20;
            if (8 + i * 20 + 20 > (uint32_t)len) break;
            if ((cpu_type_t)sb_be32(arch) == host) {
                uint32_t o = sb_be32(arch + 8), s = sb_be32(arch + 12);
                if ((uint64_t)o + s <= (uint64_t)len) {
                    slice = data + o;
                    len = s;
                }
                break;
            }
        }
    }
    verdict = sb_slice_honored(slice, (size_t)len);
    free(data);
    errno = 0;
    return verdict;
}

#ifdef SPAWN_BRIDGE_PROBE_MAIN
int
main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <path>\n", argv[0]);
        return 64;
    }
    printf("%d\n", tebako_fs_exec_dyld_insertion_honored(argv[1]));
    return 0;
}
#endif /* SPAWN_BRIDGE_PROBE_MAIN */

#endif /* SPAWN_BRIDGE_PROBE */
