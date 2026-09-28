// release-tty COMMAND [ARGUMENT...]: gives up the controlling terminal, then becomes COMMAND.
//
// flutter_pty2 starts a terminal's program as the leader of a new session whose controlling terminal is the PTY. In
// the Flatpak that program is `flatpak-spawn --host`, and the shell it starts runs in a session of its own on the
// host. That shell can make the PTY its controlling terminal, which gives it job control and lets ^C and SIGWINCH
// reach its foreground job, only while no other session holds the PTY. So this program lets go of it first.
#include <signal.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
  if (argc < 2) {
    fputs("usage: release-tty COMMAND [ARGUMENT...]\n", stderr);
    return 2;
  }
  // A session leader that gives up its terminal sends SIGHUP to the terminal's foreground process group, its own.
  signal(SIGHUP, SIG_IGN);
  if (ioctl(STDIN_FILENO, TIOCNOTTY) != 0) {
    perror("release-tty: TIOCNOTTY");
    return 126;
  }
  signal(SIGHUP, SIG_DFL);
  execvp(argv[1], argv + 1);
  perror("release-tty: exec");
  return 127;
}
