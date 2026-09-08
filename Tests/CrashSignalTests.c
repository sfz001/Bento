#include <signal.h>
#include <stdlib.h>
int bento_install_crash_logger(const char *path);
int main(int argc, char **argv) {
    if (argc != 3 || bento_install_crash_logger(argv[1]) != 0) return 2;
    raise(atoi(argv[2]));
    return 3;
}
