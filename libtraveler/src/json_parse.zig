const std = @import("std");

pub fn extractFirstJSONObjectAlloc(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var start: ?usize = null;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;

    for (text, 0..) |ch, idx| {
        if (in_string) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') {
                in_string = false;
            }
            continue;
        }

        switch (ch) {
            '"' => in_string = true,
            '{' => {
                if (start == null) start = idx;
                depth += 1;
            },
            '}' => {
                if (depth == 0) continue;
                depth -= 1;
                if (depth == 0 and start != null) {
                    return alloc.dupe(u8, text[start.? .. idx + 1]);
                }
            },
            else => {},
        }
    }
    return error.NoJsonObjectFound;
}

test "extracts fenced json" {
    const alloc = std.testing.allocator;
    const raw =
        \\```json
        \\{"header":{"product_name":"VS-200"}}
        \\```
    ;
    const actual = try extractFirstJSONObjectAlloc(alloc, raw);
    defer alloc.free(actual);
    try std.testing.expectEqualStrings("{\"header\":{\"product_name\":\"VS-200\"}}", actual);
}
