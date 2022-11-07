const std = @import("std");
const parser = @import("parser.zig");
const testing = std.testing;

fn tomlValueToJson(allocator: std.mem.Allocator, v: *parser.Value) !std.json.Value {
    return switch (v.*) {
        .string => |s| std.json.Value{ .String = s },
        .integer => |s| std.json.Value{ .Integer = s },
        .boolean => |b| std.json.Value{ .Bool = b },
        .array => |*a| b: {
            var al = try std.json.Array.initCapacity(allocator, a.items.len);
            for (a.items) |*value| {
                al.appendAssumeCapacity(try tomlValueToJson(allocator, value));
            }
            break :b std.json.Value{ .Array = al };
        },
        .table => |*t| try tableToJson(allocator, t),
    };
}

fn tableToJson(allocator: std.mem.Allocator, table: *parser.Table) error{OutOfMemory}!std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer obj.deinit();

    var it = table.table.iterator();
    while (it.next()) |entry| {
        const v = try tomlValueToJson(allocator, entry.value_ptr);
        try obj.put(entry.key_ptr.*, v);
    }

    return std.json.Value{ .Object = obj };
}

fn expectParseEqualToJson(src: []const u8, json: []const u8) !void {
    var table = try parser.parse(testing.allocator, src);
    defer table.deinit(testing.allocator);

    var actual_al = std.ArrayList(u8).init(testing.allocator);
    defer actual_al.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var actual_json = try tableToJson(arena.allocator(), &table);
    try actual_json.jsonStringify(.{ .whitespace = .{} }, actual_al.writer());

    try testing.expectEqualStrings(json, actual_al.items);
}

test "snooker" {
    try expectParseEqualToJson(
        \\name = "snooker"
        \\
        \\[goat]
        \\name = "Ronnie o' Sullivan"
        \\age = 46 # as of Nov 2022
        \\hobbies = ["running", "hustling at pool"]
        \\
        \\[goat.triple-crowns]
        \\worlds = 7
        \\masters = 7
        \\uks = 7
    ,
        \\{
        \\    "name": "snooker",
        \\    "goat": {
        \\        "hobbies": [
        \\            "running",
        \\            "hustling at pool"
        \\        ],
        \\        "name": "Ronnie o' Sullivan",
        \\        "age": 46,
        \\        "triple-crowns": {
        \\            "masters": 7,
        \\            "worlds": 7,
        \\            "uks": 7
        \\        }
        \\    }
        \\}
    );
}

test "helix config" {
    try expectParseEqualToJson(
        \\theme = "ayu_dark"
        \\
        \\[editor]
        \\line-number = "relative"
        \\rulers = [80, 120]
        \\scrolloff = 0
        \\true-color = true
        \\
        \\[editor.cursor-shape]
        \\insert = "bar"
        \\normal = "block"
        \\select = "underline"
        \\
        \\[editor.statusline]
        \\center = ["file-name"]
        \\left = ["mode", "spinner"]
        \\right = ["diagnostics", "selections", "position", "position-percentage", "file-encoding", "file-type"]
        \\separator = "│"
        \\
        \\[keys.normal]
        \\"," = "collapse_selection"
        \\";" = "keep_primary_selection"
        \\A-J = "join_selections"
        \\A-K = "remove_selections"
        \\A-k = "keep_selections"
        \\B = "extend_prev_word_start"
        \\E = "extend_next_word_end"
        \\H = "extend_char_left"
        \\J = "extend_line_down"
        \\K = "extend_line_up"
        \\L = "extend_char_right"
        \\N = "extend_search_next"
        \\W = "extend_next_word_start"
        \\X = "extend_line_below"
        \\
        \\[keys.normal.space]
        \\"," = "buffer_picker"
        \\space = "file_picker"
        \\
        \\[keys.normal.space.c]
        \\D = "workspace_diagnostics_picker"
        \\R = "rename_symbol"
        \\S = "workspace_symbol_picker"
        \\a = "code_action"
        \\d = "diagnostics_picker"
        \\s = "symbol_picker"
    ,
        \\{
        \\    "keys": {
        \\        "normal": {
        \\            "A-K": "remove_selections",
        \\            "N": "extend_search_next",
        \\            "E": "extend_next_word_end",
        \\            "space": {
        \\                "space": "file_picker",
        \\                ",": "buffer_picker",
        \\                "c": {
        \\                    "S": "workspace_symbol_picker",
        \\                    "R": "rename_symbol",
        \\                    "a": "code_action",
        \\                    "d": "diagnostics_picker",
        \\                    "s": "symbol_picker",
        \\                    "D": "workspace_diagnostics_picker"
        \\                }
        \\            },
        \\            "W": "extend_next_word_start",
        \\            ";": "keep_primary_selection",
        \\            "B": "extend_prev_word_start",
        \\            "L": "extend_char_right",
        \\            "A-k": "keep_selections",
        \\            "X": "extend_line_below",
        \\            ",": "collapse_selection",
        \\            "A-J": "join_selections",
        \\            "K": "extend_line_up",
        \\            "H": "extend_char_left",
        \\            "J": "extend_line_down"
        \\        }
        \\    },
        \\    "theme": "ayu_dark",
        \\    "editor": {
        \\        "line-number": "relative",
        \\        "statusline": {
        \\            "right": [
        \\                "diagnostics",
        \\                "selections",
        \\                "position",
        \\                "position-percentage",
        \\                "file-encoding",
        \\                "file-type"
        \\            ],
        \\            "left": [
        \\                "mode",
        \\                "spinner"
        \\            ],
        \\            "separator": "│",
        \\            "center": [
        \\                "file-name"
        \\            ]
        \\        },
        \\        "cursor-shape": {
        \\            "normal": "block",
        \\            "insert": "bar",
        \\            "select": "underline"
        \\        },
        \\        "scrolloff": 0,
        \\        "rulers": [
        \\            80,
        \\            120
        \\        ],
        \\        "true-color": true
        \\    }
        \\}
    );
}
