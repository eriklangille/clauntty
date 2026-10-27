#include <string>
#include <vector>

namespace review {

template <typename T>
class Ring {
public:
    explicit Ring(std::size_t capacity) : items_(capacity) {}
    void push(const T& value) { items_[head_++ % items_.size()] = value; }
    [[nodiscard]] bool empty() const noexcept { return head_ == 0; }

private:
    std::vector<T> items_;
    std::size_t head_ = 0;
};

}  // namespace review

auto main() -> int {
    review::Ring<std::string> ring{8};
    ring.push(R"(raw "string")");
    return ring.empty() ? 1 : 0;
}
