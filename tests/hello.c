// C23: constexpr objects, typeof, nullptr, bool keyword, digit separators, #embed.
#include <stdio.h>
#include <string.h>

static const unsigned char self[] = {
#embed "hello.c" limit(16)
};

[[nodiscard]] static int square(int x) { return x * x; }

int main(void) {
    constexpr int n = 1'000;
    typeof(n) sq = square(n);
    int *p = nullptr;
    bool ok = sq == 1'000'000 && p == nullptr && memcmp(self, "// C23: constexp", 16) == 0;
    printf("C23 ok=%d\n", ok);
    return ok ? 0 : 1;
}
