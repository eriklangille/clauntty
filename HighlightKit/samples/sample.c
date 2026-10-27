#include <stdio.h>
#include "tree_sitter/api.h"

#define MAX_BYTES (512 * 1024)

/* Count the lines in a buffer */
static unsigned line_count(const char *text, size_t len) {
    unsigned n = 0;
    for (size_t i = 0; i < len; i++) {
        if (text[i] == '\n') n++;
    }
    return len > 0 && text[len - 1] != '\n' ? n + 1 : n;
}

int main(void) {
    printf("%u lines\n", line_count("a\nb", 3));
    return 0;
}
