const std = @import("std");
const lex = @import("lexer.zig");
const testing = std.testing;

/// Lexer is a wrapper enum so we can do static dispatch on real/fake lexers for testing purposes
const Lexer = union(enum) {
    real: lex.Lexer,
    fake: lex.Fake,

    fn next(self: *Lexer) lex.Lexer.Error!?lex.TokLoc {
        return switch (self.*) {
            .real => |*r| r.next(),
            .fake => |*f| f.next(),
        };
    }
};

/// Table represents a TOML table (i.e. dicitonary/hashmap). It assumes that the key and value were allocated with the
/// same allocator
pub const Table = struct {
    table: TableBase = .{},

    const TableBase = std.StringHashMapUnmanaged(Value);

    pub fn hasKey(self: *Table, key: []const u8) bool {
        return self.table.get(key) != null;
    }

    pub fn insert(self: *Table, allocator: std.mem.Allocator, key: []const u8, value: Value) !void {
        return try self.table.put(allocator, key, value);
    }

    pub fn getOrPutTable(self: *Table, allocator: std.mem.Allocator, key: []const u8, value: Table) !*Table {
        var v = try self.table.getOrPutValue(allocator, key, .{ .table = value });
        if (v.value_ptr.* != .table) return error.not_table;

        return &v.value_ptr.table;
    }

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }

        self.table.deinit(allocator);
    }
};

/// Value represents a TOML value: i.e. an integer, string, float, boolean, table, array
pub const Value = union(enum) {
    integer: i64,
    string: []const u8,
    table: Table,
    boolean: bool,

    fn dupe(self: *const Value, allocator: std.mem.Allocator) !Value {
        return switch (self.*) {
            .string => |s| Value{ .string = try allocator.dupe(u8, s) },
            .table => |t| b: {
                var new_table = Table{};
                var it = t.table.iterator();
                while (it.next()) |entry| {
                    try new_table.insert(
                        allocator,
                        try allocator.dupe(u8, entry.key_ptr.*),
                        try entry.value_ptr.dupe(allocator),
                    );
                }
                break :b Value{ .table = new_table };
            },
            else => return self.*,
        };
    }

    fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            Value.table => |*t| t.deinit(allocator),
            Value.string => |*s| allocator.free(s.*),
            else => {},
        }
    }
};

/// Parser takes a Lexer and parses the tokens into a table.
const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: Lexer,
    peeked: ?lex.TokLoc = null,
    diag: ?lex.Diagnostic = null,
    top_level_table: *Table,
    current_table: *Table,

    fn init(allocator: std.mem.Allocator, lexer: Lexer) !Parser {
        var table = try allocator.create(Table);
        table.* = .{};
        return .{ .allocator = allocator, .lexer = lexer, .top_level_table = table, .current_table = table };
    }

    fn peek(self: *Parser) !lex.TokLoc {
        if (self.peeked) |tokloc| return tokloc;

        self.peeked = try self.lexer.next();
        return self.peeked orelse error.eof;
    }

    fn pop(self: *Parser) !lex.TokLoc {
        if (self.peeked) |tokloc| {
            self.peeked = null;
            return tokloc;
        }

        const next = try self.lexer.next();
        return next orelse error.eof;
    }

    /// expect asserts that the current token has the same tag as expected.
    ///
    /// NOTE: If the token stores a value (e.g. boolean, string) then it does not check that the value is the same
    fn expect(self: *Parser, comptime expected: lex.Tok, comptime str: []const u8) !void {
        const actual = try self.pop();
        if (std.meta.activeTag(actual.tok) != std.meta.activeTag(expected)) {
            self.diag = .{
                .msg = "expected '" ++ str ++ "'",
                .loc = actual.loc,
            };
            return error.unexpected_token;
        }
    }

    /// parseKey parses a potentially nested (i.e. with dots in) key and returns the table any subsequent value should
    /// be in, alongside the final key. If any table in the path does not exist then it will create it.
    fn parseKey(self: *Parser, key: []const u8) !struct { tbl: *Table, key: []const u8 } {
        var dup: []const u8 = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(dup);

        const next = try self.peek();
        switch (next.tok) {
            .equals, .close_square_bracket => return .{ .tbl = self.current_table, .key = dup },
            .dot => {
                _ = self.pop() catch unreachable;

                const existed = self.current_table.hasKey(dup);
                var new = try self.current_table.getOrPutTable(self.allocator, dup, .{});
                var curr = self.current_table;
                self.current_table = new;

                const key_tok = try self.pop();
                const key_s = switch (key_tok.tok) {
                    .key => |k| k,
                    .string => |s| s,
                    else => {
                        self.diag = .{
                            .msg = "expected key after '.'",
                            .loc = key_tok.loc,
                        };
                        return error.unexpected_token;
                    },
                };
                const res = try self.parseKey(key_s);

                if (existed) self.allocator.free(dup);
                self.current_table = curr;

                return res;
            },
            else => {
                self.diag = .{
                    .msg = "expected '.', ']' or '=' after key",
                    .loc = next.loc,
                };
                return error.unexpected_token;
            },
        }
    }

    /// parseAssignment parses a key/value assignent to `key`, followed by either a newline or EOF
    fn parseAssignment(self: *Parser, loc: lex.Loc, key: []const u8) !void {
        const curr = self.current_table;
        const res = try self.parseKey(key);
        errdefer self.allocator.free(res.key);
        self.current_table = curr;

        try self.expect(.equals, "=");

        if (res.tbl.hasKey(res.key)) {
            self.diag = .{
                .msg = "key already exists",
                .loc = loc,
            };
            return error.key_already_exists;
        }

        const tokloc = try self.pop();
        var val = switch (tokloc.tok) {
            .string => |s| Value{ .string = try self.allocator.dupe(u8, s) },
            .integer => |i| Value{ .integer = i },
            .boolean => |b| Value{ .boolean = b },
            else => {
                self.diag = .{
                    .msg = "expected value type",
                    .loc = tokloc.loc,
                };
                return error.unexpected_token;
            },
        };
        errdefer val.deinit(self.allocator);

        try res.tbl.insert(self.allocator, res.key, val);
        // we have errdefer'ed freeing dup and val above, therefore we need to remove them from current_table so we
        // don't try to double free them when we deinit current_table
        errdefer _ = res.tbl.table.remove(res.key);

        self.expect(.newline, "\n") catch |err| switch (err) {
            error.eof => return,
            else => return err,
        };
    }

    fn parseTableHeader(self: *Parser) !void {
        std.debug.assert(self.current_table == self.top_level_table);

        const tokloc = try self.pop();
        const key = switch (tokloc.tok) {
            .key => |k| k,
            .string => |s| s,
            else => {
                std.debug.print("{}\n", .{tokloc});
                self.diag = .{ .msg = "expected key inside of square brackets", .loc = tokloc.loc };
                return error.unexpected_token;
            },
        };

        const res = try self.parseKey(key);
        errdefer self.allocator.free(res.key);

        self.current_table = try res.tbl.getOrPutTable(self.allocator, res.key, .{});
        // We've errdefer'ed freeing dup
        errdefer _ = res.tbl.table.remove(res.key);

        try self.expect(.close_square_bracket, "]");
        try self.expect(.newline, "\n");
    }

    fn parse(self: *Parser) !Table {
        while (true) {
            const tokloc = self.pop() catch |err| switch (err) {
                error.eof => {
                    const table = self.top_level_table.*;
                    self.allocator.destroy(self.top_level_table);

                    self.top_level_table = try self.allocator.create(Table);
                    self.top_level_table.* = .{};
                    self.current_table = self.top_level_table;
                    return table;
                },
                else => return err,
            };

            switch (tokloc.tok) {
                .key => |k| try self.parseAssignment(tokloc.loc, k),
                .string => |s| try self.parseAssignment(tokloc.loc, s),
                .open_square_bracket => {
                    self.current_table = self.top_level_table;
                    try self.parseTableHeader();
                },
                .newline => {},
                else => {
                    self.diag = .{
                        .msg = "expected key",
                        .loc = tokloc.loc,
                    };
                    return error.unexpected_token;
                },
            }
        }
    }

    fn deinit(self: *Parser) void {
        self.top_level_table.deinit(self.allocator);
        self.allocator.destroy(self.top_level_table);
    }
};

/// parse takes a given TOML source and returns a Table which has been allocated with the given allocator.
pub fn parse(allocator: std.mem.Allocator, src: []const u8) !Table {
    var lexer = Lexer{ .real = lex.Lexer.init(allocator, src) };
    var parser = try Parser.init(allocator, lexer);
    defer parser.deinit();

    return try parser.parse();
}

const KV = struct { k: []const u8, v: Value };

fn kvsToTable(kvs: []const KV) !Table {
    var table = Table{};
    for (kvs) |entry| {
        const v = try entry.v.dupe(testing.allocator);
        try table.insert(testing.allocator, try testing.allocator.dupe(u8, entry.k), v);
    }
    return table;
}

fn expectEqualTables(expected: Table, actual: Table) !void {
    try testing.expectEqual(expected.table.count(), actual.table.count());

    var it = expected.table.iterator();
    while (it.next()) |entry| {
        var value = actual.table.get(entry.key_ptr.*);
        try testing.expect(value != null);
        try testing.expectEqual(std.meta.activeTag(entry.value_ptr.*), std.meta.activeTag(value.?));

        switch (entry.value_ptr.*) {
            .string => |s| try testing.expectEqualStrings(s, value.?.string),
            else => try testing.expectEqual(entry.value_ptr.*, value.?),
        }
    }
}

fn toksToLocToks(toks: []const lex.Tok) ![]lex.TokLoc {
    const loc = lex.Loc{ .line = 1, .col = 1 };

    var al = std.ArrayListUnmanaged(lex.TokLoc){};
    for (toks) |tok| {
        try al.append(testing.allocator, .{ .tok = tok, .loc = loc });
    }

    return al.items;
}

fn expectEqualParses(toks: []const lex.Tok, expected: []const KV) !void {
    var parsed_table = try testParse(toks);
    defer parsed_table.deinit(testing.allocator);

    var expected_table = try kvsToTable(expected);
    defer expected_table.deinit(testing.allocator);

    try expectEqualTables(expected_table, parsed_table);
}

fn testParse(toks: []const lex.Tok) !Table {
    var toklocs = try toksToLocToks(toks);
    defer testing.allocator.free(toklocs);

    var lexer = Lexer{ .fake = .{ .toklocs = toklocs } };

    var parser = try Parser.init(testing.allocator, lexer);
    defer parser.deinit();

    return try parser.parse();
}

fn expectErrorParse(err: anyerror, toks: []const lex.Tok) !void {
    var toklocs = try toksToLocToks(toks);
    defer testing.allocator.free(toklocs);

    var lexer = Lexer{ .fake = .{ .toklocs = toklocs } };
    var parser = try Parser.init(testing.allocator, lexer);
    defer parser.deinit();

    try testing.expectError(err, parser.parse());
}

test "default table assignment" {
    try expectEqualParses(
        &.{ .{ .key = "foo" }, .equals, .{ .string = "a" } },
        &.{.{ .k = "foo", .v = .{ .string = "a" } }},
    );

    try expectEqualParses(
        &.{ .{ .key = "foo" }, .equals, .{ .integer = 147 } },
        &.{.{ .k = "foo", .v = .{ .integer = 147 } }},
    );

    try expectEqualParses(
        &.{ .{ .key = "foo" }, .equals, .{ .boolean = true } },
        &.{.{ .k = "foo", .v = .{ .boolean = true } }},
    );

    try expectEqualParses(
        &.{ .{ .string = "foo" }, .equals, .{ .string = "a" }, .newline, .{ .key = "bar" }, .equals, .{ .string = "b" } },
        &.{
            .{ .k = "foo", .v = .{ .string = "a" } },
            .{ .k = "bar", .v = .{ .string = "b" } },
        },
    );
}

test "fail: default table assignment" {
    try expectErrorParse(error.unexpected_token, &.{.equals});
    try expectErrorParse(error.unexpected_token, &.{ .{ .key = "foo" }, .newline });
    try expectErrorParse(error.unexpected_token, &.{ .{ .string = "foo" }, .equals, .{ .string = "a" }, .{ .key = "bar" }, .equals, .{ .string = "b" } });
    try expectErrorParse(error.unexpected_token, &.{ .{ .key = "foo" }, .equals, .{ .key = "a" } });
    try expectErrorParse(error.unexpected_token, &.{ .{ .integer = 147 }, .equals, .{ .string = "a" } });
    try expectErrorParse(error.unexpected_token, &.{ .{ .boolean = true }, .equals, .{ .string = "a" } });
}

test "dotted assignment" {
    // zig fmt: off
    {
        var table = try testParse(&.{ .{ .key = "foo"}, .dot, .{ .key = "bar" }, .equals, .{ .string = "a" }});
        defer table.deinit(testing.allocator);
        
        try testing.expectEqualStrings("a", table.table.get("foo").?.table.table.get("bar").?.string);
    }

    {
        var table = try testParse(&.{ 
            .{ .key = "foo"}, .dot, .{ .key = "bar" }, .equals, .{ .string = "a" }, .newline,
            .{ .key = "foo"}, .dot, .{ .key = "baz" }, .equals, .{ .string = "b" }, .newline,
        });
        defer table.deinit(testing.allocator);
        try testing.expectEqualStrings("a", table.table.get("foo").?.table.table.get("bar").?.string);
        try testing.expectEqualStrings("b", table.table.get("foo").?.table.table.get("baz").?.string);
    }

    {
        var table = try testParse(&.{ 
            .{ .key = "foo"}, .dot, .{ .key = "bar" }, .equals, .{ .string = "a" }, .newline,
            .{ .key = "foo"}, .dot, .{ .string = "baz baz" }, .equals, .{ .string = "b" }, .newline,
        });
        defer table.deinit(testing.allocator);
        try testing.expectEqualStrings("a", table.table.get("foo").?.table.table.get("bar").?.string);
        try testing.expectEqualStrings("b", table.table.get("foo").?.table.table.get("baz baz").?.string);
    }
    // zig fmt: on
}

test "fail: dotted assignment" {
    try expectErrorParse(error.key_already_exists, &.{
        .{ .key = "foo" }, .dot, .{ .key = "bar" }, .equals, .{ .string = "a" }, .newline,
        .{ .key = "foo" }, .dot, .{ .key = "bar" }, .equals, .{ .string = "b" }, .newline,
    });
}

test "table header" {
    // zig fmt: off
    {
        var table = try testParse(&.{ 
            .open_square_bracket, .{ .key="foo" }, .close_square_bracket, .newline,
            .{ .key = "bar"}, .equals, .{ .string = "a" }, .newline,
            .{ .key = "baz" }, .equals, .{ .string = "b" }, .newline,
        });
        defer table.deinit(testing.allocator);
        try testing.expectEqualStrings("a", table.table.get("foo").?.table.table.get("bar").?.string);
        try testing.expectEqualStrings("b", table.table.get("foo").?.table.table.get("baz").?.string);
    }

    {
        var table = try testParse(&.{ 
            .open_square_bracket, .{ .key="foo" }, .close_square_bracket, .newline,
            .{ .key = "bar"}, .equals, .{ .string = "a" }, .newline,
            .newline, 
            .newline, 
            .newline,
            .{ .key = "baz" }, .equals, .{ .string = "b" }, .newline,
        });
        defer table.deinit(testing.allocator);
        try testing.expectEqualStrings("a", table.table.get("foo").?.table.table.get("bar").?.string);
        try testing.expectEqualStrings("b", table.table.get("foo").?.table.table.get("baz").?.string);
    }

    {
        var table = try testParse(&.{ 
            .open_square_bracket, .{ .key="foo" }, .dot, .{.key = "bar"}, .close_square_bracket, .newline,
            .{ .key = "baz" }, .equals, .{ .string = "a" }, .newline,
            .{ .key = "bat" }, .equals, .{ .string = "b" }, .newline,
        });
        defer table.deinit(testing.allocator);
        try testing.expectEqualStrings(
            "a", 
            table.table.get("foo").?.table.table.get("bar").?.table.table.get("baz").?.string);
        try testing.expectEqualStrings(
            "b",
            table.table.get("foo").?.table.table.get("bar").?.table.table.get("bat").?.string);
    }

    {
        var table = try testParse(&.{ 
            .open_square_bracket, .{ .key="foo" }, .close_square_bracket, .newline,
            .{ .key = "a"}, .equals, .{ .integer = 1 }, .newline,
            .open_square_bracket, .{ .key="bar" }, .close_square_bracket, .newline,
            .{ .key = "b" }, .equals, .{ .integer = 2 }, .newline,
        });
        defer table.deinit(testing.allocator);
        try testing.expectEqual(@as(i64, 1), table.table.get("foo").?.table.table.get("a").?.integer);
        try testing.expectEqual(@as(i64, 2), table.table.get("bar").?.table.table.get("b").?.integer);
    }
    // zig fmt: on
}

test "fail: table header" {
    try expectErrorParse(error.eof, &.{ .open_square_bracket, .{ .key = "foo" } });
    try expectErrorParse(error.unexpected_token, &.{ .open_square_bracket, .{ .key = "foo" }, .equals });
}
