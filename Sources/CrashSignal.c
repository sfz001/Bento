#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

static char log_path[PATH_MAX];
static unsigned char signal_stack[64 * 1024];

/* Only async-signal-safe operations here. Open the current pathname so log
   rotation cannot leave the marker attached to an unlinked old file. */
static void record_crash(int sig) {
    const char *message = "[fatal] unknown signal\n";
    size_t size = sizeof("[fatal] unknown signal\n") - 1;
#define MARK(name) case name: message = "[fatal] " #name "\n"; size = sizeof("[fatal] " #name "\n") - 1; break
    switch (sig) {
        MARK(SIGTRAP); MARK(SIGILL); MARK(SIGABRT);
        MARK(SIGBUS); MARK(SIGSEGV); MARK(SIGFPE);
    }
#undef MARK
    int fd = open(log_path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd >= 0) { (void)write(fd, message, size); close(fd); }
    struct sigaction action = {0};
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    sigaction(sig, &action, NULL);
    /* The signal is pending until this handler returns. Default handling keeps
       the original signal exit status and the system crash report. */
    kill(getpid(), sig);
}

int bento_install_crash_logger(const char *path) {
    if (strlen(path) >= sizeof(log_path)) return -1;
    strcpy(log_path, path);
    stack_t stack = { .ss_sp = signal_stack, .ss_size = sizeof(signal_stack), .ss_flags = 0 };
    if (sigaltstack(&stack, NULL) != 0) return -1;
    struct sigaction action = {0};
    action.sa_handler = record_crash;
    action.sa_flags = SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    const int signals[] = {SIGTRAP, SIGILL, SIGABRT, SIGBUS, SIGSEGV, SIGFPE};
    for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) {
        if (sigaction(signals[i], &action, NULL) != 0) return -1;
    }
    return 0;
}
