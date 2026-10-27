const std = @import("std");

/// Bigger than this, a file comes collapsed
const max_file_bytes: usize = 512 * 1024;

pub fn lineCount(text: []const u8) u32 {
    if (text.len == 0) return 0;
    var n: u32 = @intCast(std.mem.count(u8, text, "\n"));
    // A last line without a newline counts too
    if (text[text.len - 1] != '\n') n += 1;
    return n;
}

test "lineCount" {
    try std.testing.expectEqual(@as(u32, 2), lineCount("a\nb"));
}
