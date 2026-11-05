// Debugged by gdb in run-tests.sh to check DWARF 5 and libstdc++ pretty-printers.
#include <map>
#include <string>
#include <vector>

int main() {
    std::vector<int> v{1, 2, 3};
    std::map<std::string, int> m{{"a", 1}};
    return static_cast<int>(v.size() + m.size()) - 4;  // break here
}
