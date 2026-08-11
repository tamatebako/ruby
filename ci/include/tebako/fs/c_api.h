#ifndef TEBAKO_FS_C_API_H
#define TEBAKO_FS_C_API_H

/* Compile-smoke stub (release-src.yml compile-smoke legs), NOT the real
 * libtfs header. Declares exactly the <tebako/fs/c_api.h> surface the
 * canonical patches reference, mirroring the real header's signatures
 * (libtfs-capiwt include/tebako/fs/c_api.h), so the patched translation
 * units can be compiled without building libtfs. If a patch starts using
 * more of the c_api, extend this stub in the same change. */

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/stat.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef DT_REG
#define DT_REG 8
#endif
#ifndef DT_DIR
#define DT_DIR 4
#endif

#define TEBAKO_FD_FLAG 0x40000000
#define TEBAKO_FD_MAX 0x0FFFFFFF

/* The stat ABI, mirroring the authority (libtfs include/tebako/fs/c_api.h)
 * exactly: the pinned __stat64 layout on Windows (64-bit st_size, 56
 * bytes with natural 8-byte alignment of the i64 fields), the platform
 * struct stat elsewhere. Keep the layout asserts identical — a drift between
 * this stub and the authority is a compile error here, never a silent
 * ABI fork. */
#if defined(_WIN32)
struct tebako_stat {
    uint32_t st_dev;    /* offset  0 */
    uint16_t st_ino;    /* offset  4 */
    uint16_t st_mode;   /* offset  6 */
    int16_t  st_nlink;  /* offset  8 */
    int16_t  st_uid;    /* offset 10 */
    int16_t  st_gid;    /* offset 12 */
    uint32_t st_rdev;   /* offset 14 */
    /* 2 bytes padding to the 8-aligned i64 */
    int64_t  st_size;   /* offset 24 */
    int64_t  st_atime;  /* offset 32 */
    int64_t  st_mtime;  /* offset 40 */
    int64_t  st_ctime;  /* offset 48 */
};                      /* sizeof 56 */
_Static_assert(sizeof(struct tebako_stat) == 56, "tebako_stat ABI drift");
_Static_assert(offsetof(struct tebako_stat, st_size) == 24, "tebako_stat ABI drift");
_Static_assert(offsetof(struct tebako_stat, st_mtime) == 40, "tebako_stat ABI drift");
#else
#define tebako_stat stat
#endif

int tebako_fs_open(const char* path, int flags);
ssize_t tebako_fs_read(int fd, void* buf, size_t count);
ssize_t tebako_fs_pread(int fd, void* buf, size_t nbyte, off_t offset);
off_t tebako_fs_lseek(int fd, off_t offset, int whence);
int tebako_fs_close(int fd);

typedef void* tebako_dir_t;

struct tebako_c_dirent {
  char d_name[256];
  unsigned char d_type;
};

tebako_dir_t tebako_fs_opendir(const char* path);
struct tebako_c_dirent* tebako_fs_readdir(tebako_dir_t dir);
int tebako_fs_closedir(tebako_dir_t dir);
int tebako_fs_dir_is_embedded(tebako_dir_t dir);
void tebako_fs_rewinddir(tebako_dir_t dir);
long tebako_fs_telldir(tebako_dir_t dir);
void tebako_fs_seekdir(tebako_dir_t dir, long pos);

int tebako_fs_stat(const char* path, struct tebako_stat* st);
int tebako_fs_fstat(int fd, struct tebako_stat* st);

int tebako_path_is_embedded(const char* path);
int tebako_fd_is_embedded(int fd);
int tebako_get_errno(void);

char* tebako_fs_dlmap2file(const char* path);
char* tebako_fs_exec_materialize(const char* path);
char* tebako_fs_mounts(void);
char* tebako_fs_mount_of(const char* path);

#ifdef __cplusplus
}
#endif

#endif /* TEBAKO_FS_C_API_H */
