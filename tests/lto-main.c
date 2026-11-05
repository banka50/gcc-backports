#include <stdio.h>

int twice(int x);

int main(void) {
    int r = twice(21);
    printf("LTO r=%d\n", r);
    return r == 42 ? 0 : 1;
}
