# Repository rules — C++ codebase

This repository is C++17/20 built with CMake, using the standard library and RAII for resource management. Review `.cpp`, `.cc`, `.h`, `.hpp` and `CMakeLists.txt` changes according to the rules below.

## C++ rules

### Memory safety

1. A write past the end of a buffer is CRITICAL: `strcpy`, `strcat`, `sprintf`, `gets`, `memcpy` or `std::copy` into a fixed-size buffer without a checked length, or indexing an array, `std::vector` or pointer with a value from input that is not bounds-checked.
2. Use after free or a dangling reference is CRITICAL: returning a pointer, reference, `std::string_view` or `std::span` to a local or a temporary; keeping one to a container element across an operation that can reallocate; using an object after `delete` or after `std::move`.
3. Iterator, pointer or reference invalidation is CRITICAL: `push_back`, `insert`, `erase` or `resize` on a container while iterating it or holding iterators into it, without using the returned iterator.
4. Double `delete`, mismatched `new[]` / `delete`, or `free` on memory from `new` is CRITICAL.
5. Size arithmetic that can overflow before an allocation or a copy (`count * sizeof(T)`, `len + 1` on input sizes) is CRITICAL.
6. Reading an uninitialised variable or member is WARNING.

### Injection and untrusted input

1. A format string that comes from input (`printf(msg)`, `syslog(prio, msg)`) is CRITICAL.
2. Input passed to `system`, `popen` or a shell is CRITICAL.
3. A file path from input without checking it stays under the intended root is CRITICAL.

### Ownership and lifetime

1. Owning raw pointers with manual `new` / `delete` in new code are WARNING; use `std::unique_ptr`, `std::make_unique` or a container.
2. A class that owns a resource without following the rule of zero, three or five (a destructor without matching copy and move handling) is WARNING.
3. A base class with virtual functions and a public non-virtual destructor that is deleted through a base pointer is WARNING.
4. Throwing from a destructor is WARNING.

### Concurrency

1. Data shared between threads and written by at least one, without a mutex, atomic or other synchronisation, is WARNING (data race, undefined behaviour).
2. Calling `lock()` / `unlock()` by hand instead of `std::lock_guard`, `std::scoped_lock` or `std::unique_lock` is WARNING: an exception leaves the mutex locked.
3. A `std::thread` that can be destroyed while joinable (not joined or detached on every path) is WARNING: it calls `std::terminate`. Prefer `std::jthread`.
4. Locking two mutexes in different orders in different places is WARNING (deadlock).

### Correctness

1. Comparing signed and unsigned values in a loop condition or size check, or narrowing a `size_t` into `int`, is WARNING when the value can exceed the smaller range.
2. Ignoring the result of a function that reports failure by return value (an error code, `[[nodiscard]]`, `std::optional`, a `bool` from a write) is WARNING.
3. `reinterpret_cast` or a C-style cast for type punning is WARNING (undefined behaviour); use `std::bit_cast` or `memcpy`.
4. Catching exceptions by value is SUGGESTION; catch by `const&`.
5. A move constructor or move assignment without `noexcept` is SUGGESTION.

## Conventions to respect

Formatting and lint are enforced by clang-format and clang-tidy, and the build runs with warnings as errors; do not comment on what they report. Prefer the patterns already used in the surrounding code over generic preferences.
