// C++23 library features that need the new libstdc++ (absent from older distributions' runtimes).
#include <expected>
#include <print>
#include <ranges>
#include <string>
#include <vector>

static std::expected<int, std::string> parse(std::string_view s) {
    int v = 0;
    for (char c : s) {
        if (c < '0' || c > '9') return std::unexpected("not a number: " + std::string(s));
        v = v * 10 + (c - '0');
    }
    return v;
}

int main() {
    std::vector<std::string> in{"1", "22", "x", "333"};
    int sum = 0, errors = 0;
    for (auto &&[i, s] : std::views::enumerate(in)) {
        if (auto r = parse(s)) sum += *r;
        else { ++errors; std::println("#{}: {}", i, r.error()); }
    }
    std::println("C++23 sum={} errors={}", sum, errors);
    return (sum == 356 && errors == 1) ? 0 : 1;
}
