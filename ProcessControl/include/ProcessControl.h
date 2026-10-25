#ifndef CORE_TAMER_PROCESS_CONTROL_H
#define CORE_TAMER_PROCESS_CONTROL_H

#include <stdint.h>
#include <sys/types.h>

typedef struct {
  pid_t pid;
  uid_t uid;
  pid_t parent;
  uint64_t start_seconds;
  uint64_t start_microseconds;
  uint64_t cpu_nanoseconds;
  int stopped;
} APProcessInfo;

typedef struct {
  double credit;
  double rate;
  double capacity;
} APBudget;

// Fixed-size pipe records shared by the app, controller and its crash watchdog.
typedef enum {
  AP_MEMBER_ADD = 'A',
  AP_MEMBER_REMOVE = 'D',
  AP_WATCH_STOP = 'S',
  AP_WATCH_RESUME = 'R'
} APControlOperation;

typedef struct {
  APControlOperation operation;
  APProcessInfo identity;
} APControlMessage;

int ap_process_read(pid_t pid, APProcessInfo *info);
int ap_process_path(pid_t pid, char *buffer, uint32_t capacity);
int ap_process_name(pid_t pid, char *buffer, uint32_t capacity);
pid_t ap_process_responsible(pid_t pid);
int ap_process_list(pid_t *buffer, uint32_t capacity);
int ap_same_process(const APProcessInfo *first, const APProcessInfo *second);
int ap_validate_target(const APProcessInfo *info, pid_t controller_parent);
int ap_signal_process(const APProcessInfo *identity, int signal_number);
int ap_budget_init(APBudget *budget, double percent);
int ap_budget_update(APBudget *budget, double elapsed, double cpu_elapsed);
double ap_monotonic_seconds(void);
int ap_kernel_timebase(uint32_t *numerator, uint32_t *denominator);
uint64_t ap_ticks_to_nanoseconds(uint64_t ticks, uint32_t numerator, uint32_t denominator);

#endif
