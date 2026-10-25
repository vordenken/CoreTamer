#include "ProcessControl.h"

#include <dlfcn.h>
#include <errno.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <math.h>
#include <signal.h>
#include <string.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

int ap_process_read(pid_t pid, APProcessInfo *info) {
  if (pid <= 0 || info == NULL) return EINVAL;
  struct proc_bsdinfo bsd = {0};
  struct proc_taskinfo task = {0};
  errno = 0;
  if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd)) {
    return errno ? errno : ESRCH;
  }
  if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) != sizeof(task)) {
    return errno ? errno : ESRCH;
  }
  // Read identity again: the PID could have been reused between the two queries.
  struct proc_bsdinfo verified = {0};
  if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &verified, sizeof(verified)) != sizeof(verified)) {
    return errno ? errno : ESRCH;
  }
  if (bsd.pbi_start_tvsec != verified.pbi_start_tvsec ||
      bsd.pbi_start_tvusec != verified.pbi_start_tvusec) return ESRCH;
  uint32_t numerator, denominator;
  if (ap_kernel_timebase(&numerator, &denominator)) return EIO;
  *info = (APProcessInfo){
    .pid = pid, .uid = bsd.pbi_uid, .parent = (pid_t)bsd.pbi_ppid,
    .start_seconds = bsd.pbi_start_tvsec, .start_microseconds = bsd.pbi_start_tvusec,
    // PROC_PIDTASKINFO uses Mach ticks: unlike Intel, Apple Silicon is not 1 tick/ns.
    .cpu_nanoseconds = ap_ticks_to_nanoseconds(
      task.pti_total_user + task.pti_total_system, numerator, denominator),
    .stopped = bsd.pbi_status == SSTOP,
  };
  return 0;
}

int ap_process_path(pid_t pid, char *buffer, uint32_t capacity) {
  errno = 0;
  if (proc_pidpath(pid, buffer, capacity) > 0) return 0;
  return errno ? errno : ESRCH;
}

int ap_process_name(pid_t pid, char *buffer, uint32_t capacity) {
  errno = 0;
  if (proc_name(pid, buffer, capacity) > 0) return 0;
  return errno ? errno : ESRCH;
}

typedef pid_t (*APResponsibleFunction)(pid_t);

/*
 * macOS attributes XPC services (e.g. WebKit content processes) to the app they work for, as
 * Activity Monitor shows. The libsystem symbol is not public, so it is looked up at runtime;
 * without it every process is its own responsible process and grouping falls back to paths.
 */
pid_t ap_process_responsible(pid_t pid) {
  static APResponsibleFunction function;
  static int resolved;
  if (!resolved) {
    function = (APResponsibleFunction)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    resolved = 1;
  }
  if (pid <= 0 || function == NULL) return pid;
  pid_t responsible = function(pid);
  return responsible > 0 ? responsible : pid;
}

int ap_process_list(pid_t *buffer, uint32_t capacity) {
  return proc_listpids(PROC_ALL_PIDS, 0, buffer, (int)(capacity * sizeof(pid_t)));
}

int ap_same_process(const APProcessInfo *first, const APProcessInfo *second) {
  return first->pid == second->pid && first->uid == second->uid &&
    first->start_seconds == second->start_seconds &&
    first->start_microseconds == second->start_microseconds;
}

int ap_validate_target(const APProcessInfo *info, pid_t controller_parent) {
  if (info->pid <= 1 || info->pid == getpid() || info->pid == controller_parent ||
      info->uid != getuid() || info->uid == 0) return EPERM;
  if (info->stopped) return EBUSY;
  return 0;
}

int ap_signal_process(const APProcessInfo *identity, int signal_number) {
  APProcessInfo current;
  int error = ap_process_read(identity->pid, &current);
  if (error != 0) return error;
  if (!ap_same_process(identity, &current)) return ESRCH;
  if (kill(identity->pid, signal_number) == -1) return errno;
  return 0;
}

int ap_budget_init(APBudget *budget, double percent) {
  if (!isfinite(percent) || percent < 1 || percent > 100 * sysconf(_SC_NPROCESSORS_ONLN)) {
    return EINVAL;
  }
  budget->rate = percent / 100;
  budget->capacity = fmax(0.002, budget->rate * 0.02);
  budget->credit = budget->capacity;
  return 0;
}

int ap_budget_update(APBudget *budget, double elapsed, double cpu_elapsed) {
  budget->credit = fmin(budget->capacity, budget->credit + budget->rate * elapsed - cpu_elapsed);
  return budget->credit < 0;
}

double ap_monotonic_seconds(void) {
  struct timespec value;
  clock_gettime(CLOCK_MONOTONIC, &value);
  return value.tv_sec + value.tv_nsec / 1e9;
}

int ap_kernel_timebase(uint32_t *numerator, uint32_t *denominator) {
  if (numerator == NULL || denominator == NULL) return EINVAL;
  // Under Rosetta, mach_timebase_info reports 1/1 for translated time, but proc_pidinfo
  // still returns native kernel ticks. hw.tbfrequency reports the real kernel tick rate.
  uint64_t frequency = 0;
  size_t size = sizeof(frequency);
  if (sysctlbyname("hw.tbfrequency", &frequency, &size, NULL, 0) == 0 &&
      size == sizeof(frequency) && frequency > 0 && frequency <= UINT32_MAX) {
    *numerator = 1000000000U;
    *denominator = (uint32_t)frequency;
    return 0;
  }
  mach_timebase_info_data_t timebase;
  if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) return EIO;
  *numerator = timebase.numer;
  *denominator = timebase.denom;
  return 0;
}

uint64_t ap_ticks_to_nanoseconds(uint64_t ticks, uint32_t numerator, uint32_t denominator) {
  // Widen before multiplication so long-running processes cannot overflow the intermediate.
  return (uint64_t)((__uint128_t)ticks * numerator / denominator);
}
