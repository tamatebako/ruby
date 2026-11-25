/* ci/spawn-bridge dummy preload shim: stands in for libtfs_preload.dylib
 * so dyld has a real dylib to insert. The constructor announces the
 * loading process's pid — the harness pairs the line with the echo
 * target's own pid line to prove the shim entered the CHILD (or, for
 * the stripped shapes, that it never did). */
#include <stdio.h>
#include <unistd.h>

__attribute__((constructor)) static void
shim_boot(void)
{
    fprintf(stderr, "SPAWN-BRIDGE-SHIM-LOADED pid=%d\n", (int)getpid());
}
