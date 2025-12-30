const std = @import("std");
const value_mod = @import("../data/value.zig");
const Value = value_mod.Value;

pub fn scanIntPlain(ptr: []const u8) ?i32 {
    if (ptr.len == 0) return null;
    return std.fmt.parseInt(i32, ptr, 10) catch null;
}

pub fn scanHex(val: []const u8) ?i32 {
    if (val.len < 3) return null;
    if (!std.ascii.eqlIgnoreCase(val[0..2], "0x")) return null;

    const hex_part = val[2..];
    if (hex_part.len == 0) return null;

    for (hex_part) |c| {
        if (!std.ascii.isHex(c)) return null;
    }

    return std.fmt.parseInt(i32, hex_part, 16) catch null;
}

pub fn scanInt(input: []const u8) !?Value {
    if (input.len == 0) return null;

    if (scanIntPlain(input)) |val| {
        return Value.initI32(val);
    }

    if (scanHex(input)) |val| {
        return Value.initI32(val);
    }

    return null;
}

pub fn scanInt64Plain(ptr: []const u8) ?i64 {
    if (ptr.len == 0) return null;
    return std.fmt.parseInt(i64, ptr, 10) catch null;
}

pub fn scanInt64(input: []const u8) !?Value {
    if (input.len == 0) return null;

    if (scanInt64Plain(input)) |val| {
        return Value.initI64(val);
    }

    if (scanHex(input)) |val| {
        return Value.initI64(val);
    }

    return null;
}

pub fn scanFloatPlain(ptr: []const u8) ?f32 {
    if (ptr.len == 0) return null;
    return std.fmt.parseFloat(f32, ptr) catch null;
}

pub fn scanDb(ptr: []const u8) ?f32 {
    if (ptr.len < 3 or ptr[0] != 'd' or ptr[1] != 'b') return null;

    const db_part = ptr[2..];
    const db_value = std.fmt.parseFloat(f32, db_part) catch {
        std.debug.print("invalid db value {s}\n", .{ptr});
        return null;
    };

    return std.math.pow(f32, 10.0, db_value * (1.0 / 20.0));
}

pub fn scanFloat(ptr: []const u8) !?Value {
    if (ptr.len == 0) return null;

    if (scanFloatPlain(ptr)) |val| {
        return Value.initF32(val);
    }

    if (scanDb(ptr)) |val| {
        return Value.initF32(val);
    }

    return null;
}