#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

static void *busy(void *context) {
  (void)context;
  volatile uint64_t value = 1;
  for (;;) value = value * 6364136223846793005ULL + 1;
  return NULL;
}

int main(void) {
  pthread_t threads[4];
  for (int i = 0; i < 4; ++i) {
    int error = pthread_create(&threads[i], NULL, busy, NULL);
    if (error) {
      fprintf(stderr, "Cannot create CPU test thread: %d\n", error);
      return 1;
    }
  }
  for (int i = 0; i < 4; ++i) pthread_join(threads[i], NULL);
  return 0;
}
