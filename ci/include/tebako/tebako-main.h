#ifndef TEBAKO_MAIN_H
#define TEBAKO_MAIN_H

/* Compile-smoke stub (release-src.yml compile-smoke legs), NOT the real
 * header. Declares exactly the <tebako/tebako-main.h> surface the canonical
 * patches reference (tebako include/tebako/tebako-main.h); see the note in
 * ci/include/tebako/fs/c_api.h. */

#ifdef __cplusplus
extern "C" {
#endif

int tebako_main(int* argc, char*** argv);
const char* tebako_mount_point(void);
int tebako_is_running_miniruby(void);
const char* tebako_original_pwd(void);

#ifdef __cplusplus
}
#endif

#endif /* TEBAKO_MAIN_H */
