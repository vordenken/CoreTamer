#include "ProcessControl.h"

#include <errno.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t quitting = 0;

static void request_exit(int number) {
  (void)number;
  quitting = 1;
}

static int report(const char *operation, pid_t pid, int error) {
  fprintf(stderr, "CoreTamer controller: %s for PID %d: %s (%d).\n",
          operation, pid, strerror(error), error);
  return 1;
}

static int resume(const APProcessInfo *identity) {
  int error = ap_signal_process(identity, SIGCONT);
  if (error != 0 && error != ESRCH) return report("resume failed", identity->pid, error);
  return 0;
}

#define MAX_MEMBERS 4096

typedef struct {
  APProcessInfo identity;
  uint64_t previous_cpu;
  int stopped;
} Member;

static Member members[MAX_MEMBERS];
static size_t member_count;

static size_t member_index(const APProcessInfo *identity) {
  for (size_t i = 0; i < member_count; i++) {
    if (ap_same_process(&members[i].identity, identity)) return i;
  }
  return member_count;
}

static int notify(int descriptor, APControlOperation operation, const APProcessInfo *identity) {
  APControlMessage message = {.operation = operation, .identity = *identity};
  ssize_t written;
  do {
    written = write(descriptor, &message, sizeof(message));
  } while (written < 0 && errno == EINTR);
  return written == sizeof(message) ? 0 : report("watchdog disconnected", identity->pid, EPIPE);
}

static void watch_controller(int descriptor) {
  // STOP is recorded before signalling. EOF also covers SIGKILL of the controller.
  member_count = 0;
  APControlMessage message;
  size_t filled = 0;
  int result = 0;
  for (;;) {
    ssize_t count = read(descriptor, (char *)&message + filled, sizeof(message) - filled);
    if (count < 0 && errno == EINTR) continue;
    if (count < 0) result = report("watchdog pipe read failed", 0, errno);
    if (count <= 0) break;
    filled += (size_t)count;
    if (filled != sizeof(message)) continue;
    filled = 0;
    size_t index = member_index(&message.identity);
    if (message.operation == AP_WATCH_STOP && index == member_count) {
      if (member_count == MAX_MEMBERS) {
        result = report("watchdog member capacity exceeded", message.identity.pid, E2BIG);
        break;
      }
      members[member_count++].identity = message.identity;
    } else if (message.operation == AP_WATCH_RESUME && index < member_count) {
      members[index] = members[--member_count];
    }
  }
  if (filled) result |= report("incomplete watchdog message", 0, EINVAL);
  for (size_t i = 0; i < member_count; i++) result |= resume(&members[i].identity);
  close(descriptor);
  exit(result);
}

static int add_member(const APProcessInfo *identity, pid_t parent) {
  if (member_index(identity) < member_count) return 0;
  if (member_count == MAX_MEMBERS) return report("too many group members", identity->pid, E2BIG);
  APProcessInfo fresh;
  int error = ap_process_read(identity->pid, &fresh);
  if (error == ESRCH) return 0;  // A helper may exit while its membership update is in flight.
  if (!error && !ap_same_process(identity, &fresh)) return 0;
  if (!error) error = ap_validate_target(&fresh, parent);
  if (error) return report("cannot add group member", identity->pid, error);
  members[member_count++] = (Member){.identity = fresh, .previous_cpu = fresh.cpu_nanoseconds};
  return 0;
}

static int remove_member(size_t index, int guard_descriptor) {
  Member *member = &members[index];
  if (member->stopped) {
    if (resume(&member->identity)) return 1;
    if (notify(guard_descriptor, AP_WATCH_RESUME, &member->identity)) return 1;
  }
  members[index] = members[--member_count];
  return 0;
}

static int parse_unsigned(const char *text, unsigned long long *value) {
  char *end;
  errno = 0;
  if (*text == '-' || *text == '\0') return EINVAL;
  *value = strtoull(text, &end, 10);
  return errno || *end ? EINVAL : 0;
}

int main(int argc, char **argv) {
  int group = argc == 6 && strcmp(argv[5], "--group") == 0;
  if (argc != 5 && !group) {
    fprintf(stderr, "Usage: CoreTamerController PID START_SECONDS START_MICROSECONDS CPU_PERCENT [--group]\n");
    return 2;
  }
  unsigned long long pid, seconds, microseconds;
  if (parse_unsigned(argv[1], &pid) || pid > INT32_MAX ||
      parse_unsigned(argv[2], &seconds) || parse_unsigned(argv[3], &microseconds)) {
    return report("invalid process identity", 0, EINVAL);
  }
  char *end;
  errno = 0;
  double percent = strtod(argv[4], &end);
  APBudget budget;
  if (errno || end == argv[4] || *end || ap_budget_init(&budget, percent)) {
    return report("invalid CPU percentage", (pid_t)pid, EINVAL);
  }
  APProcessInfo identity;
  int error = ap_process_read((pid_t)pid, &identity);
  if (error) return report("cannot inspect target", (pid_t)pid, error);
  if (identity.start_seconds != seconds || identity.start_microseconds != microseconds) {
    return report("target identity changed", (pid_t)pid, ESRCH);
  }
  error = ap_validate_target(&identity, getppid());
  if (error) return report("target is not safe to control", identity.pid, error);
  members[member_count++] = (Member){.identity = identity, .previous_cpu = identity.cpu_nanoseconds};

  signal(SIGTERM, request_exit);
  signal(SIGINT, request_exit);
  signal(SIGHUP, request_exit);
  signal(SIGPIPE, SIG_IGN);
  int guard_pipe[2];
  if (pipe(guard_pipe)) return report("watchdog pipe failed", identity.pid, errno);
  pid_t watchdog = fork();
  if (watchdog == -1) return report("watchdog launch failed", identity.pid, errno);
  if (watchdog == 0) {
    close(guard_pipe[1]);
    close(STDIN_FILENO);
    watch_controller(guard_pipe[0]);
  }
  close(guard_pipe[0]);
  double previous_time = ap_monotonic_seconds();
  int result = 0;
  APControlMessage message;
  size_t filled = 0;
  while (!quitting) {
    struct pollfd parent_pipe = {.fd = STDIN_FILENO, .events = POLLIN | POLLHUP};
    int ready = poll(&parent_pipe, 1, 10);
    if (ready < 0 && errno == EINTR) continue;
    if (ready < 0) {
      result = report("parent pipe poll failed", identity.pid, errno);
      break;
    }
    if (ready > 0) {
      ssize_t count = read(STDIN_FILENO, (char *)&message + filled, sizeof(message) - filled);
      if (count < 0 && errno == EINTR) continue;
      if (count < 0) result = report("parent pipe read failed", identity.pid, errno);
      if (count <= 0) break;
      filled += (size_t)count;
      if (filled == sizeof(message)) {
        filled = 0;
        if (!group || (message.operation != AP_MEMBER_ADD && message.operation != AP_MEMBER_REMOVE)) {
          result = report("invalid membership message", identity.pid, EINVAL);
          break;
        }
        if (message.operation == AP_MEMBER_ADD) {
          result = add_member(&message.identity, getppid());
        } else {
          size_t index = member_index(&message.identity);
          if (ap_same_process(&message.identity, &identity)) {
            result = report("cannot remove group leader", identity.pid, EINVAL);
          } else if (index < member_count) {
            result = remove_member(index, guard_pipe[1]);
          }
        }
        if (result) break;
      }
    }
    double cpu_delta = 0;
    int leader_alive = 0;
    for (size_t i = 0; i < member_count;) {
      Member *member = &members[i];
      APProcessInfo current;
      error = ap_process_read(member->identity.pid, &current);
      if (error == ESRCH || (!error && !ap_same_process(&member->identity, &current))) {
        result = remove_member(i, guard_pipe[1]);
        if (result) break;
        continue;
      }
      if (error) {
        result = report("target inspection failed", member->identity.pid, error);
        break;
      }
      if (ap_same_process(&identity, &current)) leader_alive = 1;
      if (current.cpu_nanoseconds >= member->previous_cpu) {
        cpu_delta += (current.cpu_nanoseconds - member->previous_cpu) / 1e9;
      }
      member->previous_cpu = current.cpu_nanoseconds;
      i++;
    }
    if (result || !leader_alive) break;
    double now = ap_monotonic_seconds();
    int should_stop = ap_budget_update(&budget, now - previous_time, cpu_delta);
    previous_time = now;
    for (size_t i = 0; i < member_count; i++) {
      Member *member = &members[i];
      if (should_stop == member->stopped) continue;
      if (should_stop && notify(guard_pipe[1], AP_WATCH_STOP, &member->identity)) { result = 1; break; }
      error = ap_signal_process(&member->identity, should_stop ? SIGSTOP : SIGCONT);
      if (error && error != ESRCH) {
        result = report("process signal failed", member->identity.pid, error);
        break;
      }
      member->stopped = should_stop;
      if (!should_stop && notify(guard_pipe[1], AP_WATCH_RESUME, &member->identity)) { result = 1; break; }
    }
    if (result) break;
  }
  if (filled) result |= report("incomplete membership message", identity.pid, EINVAL);
  for (size_t i = 0; i < member_count; i++) {
    if (members[i].stopped) result |= resume(&members[i].identity);
  }
  close(guard_pipe[1]);
  int status;
  pid_t waited;
  do {
    waited = waitpid(watchdog, &status, 0);
  } while (waited == -1 && errno == EINTR);
  if (waited == -1) return report("watchdog wait failed", identity.pid, errno);
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    result = report("watchdog failed; check whether the target needs resuming", identity.pid, EIO);
  }
  return result;
}
