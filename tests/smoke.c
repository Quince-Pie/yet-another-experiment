/* Compiled and run inside every dev shell by `scripts/release.sh smoke`.
 * It only builds as C23 (constexpr, auto, binary literals with digit
 * separators, <stdbit.h>, <stdckdint.h>), so a shell whose default -std
 * regressed fails to compile rather than silently passing. */
#include <stdbit.h>
#include <stdckdint.h>
#include <stdio.h>

int main(void)
{
    constexpr unsigned bits = 0b1010'0101u;
    auto sum = 0;
    bool overflow = ckd_add(&sum, 40, 2);
    if (stdc_count_ones(bits) != 4 || sum != 42 || overflow)
        return 1;
    printf("%ld ok\n", __STDC_VERSION__);
    return 0;
}
