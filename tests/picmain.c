#include <stdio.h>
#include <string.h>

int picfoo(char *buf, int len);

int main(void) {
    char buf[64];
    int n = picfoo(buf, sizeof buf);
    printf("%s\n", buf);
    return (n > 0 && strcmp(buf, "pic 2+3=5") == 0) ? 0 : 1;
}
