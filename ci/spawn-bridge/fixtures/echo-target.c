/* ci/spawn-bridge echo target: the fake spawn child. Prints the
 * observables the harness asserts, one SPAWN-BRIDGE-TARGET line each:
 * its pid (paired with the shim constructor's line to prove the shim
 * entered THIS process), the two injection env vars as dyld left them,
 * and the argv vector verbatim (the bridge's rewrite surface). */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
    const char *ins = getenv("DYLD_INSERT_LIBRARIES");
    const char *mounts = getenv("TEBAKO_TFS_MOUNTS");
    int i;

    printf("SPAWN-BRIDGE-TARGET pid=%d\n", (int)getpid());
    printf("SPAWN-BRIDGE-TARGET DYLD_INSERT_LIBRARIES=%s\n",
           ins != NULL ? ins : "<unset>");
    printf("SPAWN-BRIDGE-TARGET TEBAKO_TFS_MOUNTS=%s\n",
           mounts != NULL ? mounts : "<unset>");
    for (i = 0; i < argc; i++)
        printf("SPAWN-BRIDGE-TARGET argv[%d]=%s\n", i, argv[i]);
    return 0;
}
