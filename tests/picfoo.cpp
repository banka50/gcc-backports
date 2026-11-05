// Built into a shared library with libstdc++_pic.a linked in statically, so
// the .so runs with the distribution's stock, older libstdc++.so.
#include <format>
#include <string>

extern "C" int picfoo(char *buf, int len) {
    std::string s = std::format("pic {}+{}={}", 2, 3, 2 + 3);
    if (static_cast<int>(s.size()) >= len) return -1;
    s.copy(buf, s.size());
    buf[s.size()] = '\0';
    return static_cast<int>(s.size());
}
