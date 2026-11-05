#include <omp.h>
#include <stdio.h>

int main(void) {
    long sum = 0;
    int threads = 0;
#pragma omp parallel for reduction(+ : sum)
    for (long i = 1; i <= 1000000; i++) sum += i;
#pragma omp parallel
#pragma omp single
    threads = omp_get_num_threads();
    printf("OpenMP sum=%ld threads=%d\n", sum, threads);
    return (sum == 500000500000L && threads >= 1) ? 0 : 1;
}
