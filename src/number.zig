//! Exact numeric comparison of JSON numbers.
//!
//! RFC 6902 considers numbers equal "if their values are numerically equal".
//! Converting to `f64` cannot honor that: distinct large integers collapse to
//! the same float and `1e400` overflows. Comparing the decimal text instead is
//! exact for numbers of any size, and needs neither bignums nor allocation.

const std = @import("std");

/// The pieces of a number that has already been validated.
const Decimal = struct {
    negative: bool,
    int: []const u8,
    frac: []const u8,
    exp_negative: bool,
    exp: []const u8,

    fn parse(text: []const u8) Decimal {
        var rest = text;
        const negative = rest.len > 0 and rest[0] == '-';
        if (negative) rest = rest[1..];

        const int_end = std.mem.indexOfAny(u8, rest, ".eE") orelse rest.len;
        const int = rest[0..int_end];
        rest = rest[int_end..];

        var frac: []const u8 = "";
        if (rest.len > 0 and rest[0] == '.') {
            const frac_end = std.mem.indexOfAny(u8, rest, "eE") orelse rest.len;
            frac = rest[1..frac_end];
            rest = rest[frac_end..];
        }

        var exp_negative = false;
        var exp: []const u8 = "";
        if (rest.len > 0) {
            exp = rest[1..];
            if (exp.len > 0 and (exp[0] == '+' or exp[0] == '-')) {
                exp_negative = exp[0] == '-';
                exp = exp[1..];
            }
        }
        return .{ .negative = negative, .int = int, .frac = frac, .exp_negative = exp_negative, .exp = exp };
    }

    /// Returns the digit at `i` of the integer and fraction digits taken together.
    fn digit(d: *const Decimal, i: usize) u8 {
        return if (i < d.int.len) d.int[i] else d.frac[i - d.int.len];
    }

    fn digitCount(d: *const Decimal) usize {
        return d.int.len + d.frac.len;
    }

    /// Returns the range of digits between the first and last nonzero digit,
    /// or null if the value is zero.
    fn significant(d: *const Decimal) ?struct { first: usize, last: usize } {
        var first: usize = 0;
        const count = d.digitCount();
        while (first < count and d.digit(first) == '0') first += 1;
        if (first == count) return null;
        var last = count - 1;
        while (d.digit(last) == '0') last -= 1;
        return .{ .first = first, .last = last };
    }
};

/// Returns whether `a` and `b`, which must be valid JSON numbers, have the same
/// numeric value. Negative zero equals zero.
pub fn eql(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;

    const x: Decimal = .parse(a);
    const y: Decimal = .parse(b);
    const x_digits = x.significant() orelse return y.significant() == null;
    const y_digits = y.significant() orelse return false;

    if (x.negative != y.negative) return false;
    const count = x_digits.last - x_digits.first;
    if (count != y_digits.last - y_digits.first) return false;
    for (0..count + 1) |i| {
        if (x.digit(x_digits.first + i) != y.digit(y_digits.first + i)) return false;
    }

    // With the same significant digits, the values are equal if the first
    // digit has the same magnitude: x.exp + x_shift == y.exp + y_shift.
    const x_shift = shift(&x, x_digits.first);
    const y_shift = shift(&y, y_digits.first);
    return exponentDifferenceIs(&x, &y, y_shift - x_shift);
}

/// Returns how far the digit at index `first` lies above the units digit.
fn shift(d: *const Decimal, first: usize) i128 {
    return @as(i128, @intCast(d.int.len)) - @as(i128, @intCast(first));
}

/// Returns whether `x.exp - y.exp == difference`, for exponents with any number
/// of digits.
///
/// Writing the two exponents out digit by digit, the difference is
/// `c0 + 10 * (c1 + 10 * (c2 + ...))`, where each `ci` is the difference of the
/// digits at position `i`. Peeling digits off from the bottom keeps `remaining`
/// small no matter how long the exponents are.
fn exponentDifferenceIs(x: *const Decimal, y: *const Decimal, difference: i128) bool {
    var remaining = difference;
    for (0..@max(x.exp.len, y.exp.len)) |i| {
        const step = exponentDigit(x, i) - exponentDigit(y, i);
        const rest = remaining - step;
        if (@rem(rest, 10) != 0) return false;
        remaining = @divExact(rest, 10);
    }
    return remaining == 0;
}

/// Returns the signed digit at position `i` from the end of the exponent.
fn exponentDigit(d: *const Decimal, i: usize) i128 {
    if (i >= d.exp.len) return 0;
    // Text that skipped validation may hold something other than a digit.
    const value = @as(i128, d.exp[d.exp.len - 1 - i]) - '0';
    return if (d.exp_negative) -value else value;
}

const testing = std.testing;

test "equal numbers" {
    const equal = [_][2][]const u8{
        .{ "0", "0" },
        .{ "0", "-0" },
        .{ "0", "0.0" },
        .{ "0", "0e5" },
        .{ "-0.0e-3", "0E+99999999999999999999" },
        .{ "1", "1.0" },
        .{ "1", "1.000" },
        .{ "1", "1e0" },
        .{ "1", "1E0" },
        .{ "1", "1e+0" },
        .{ "1", "1e-0" },
        .{ "1", "10e-1" },
        .{ "1", "0.1e1" },
        .{ "1", "0.01e2" },
        .{ "100", "1e2" },
        .{ "100", "1.0e2" },
        .{ "120", "1.2e2" },
        .{ "-120", "-1.2E+2" },
        .{ "0.00012", "1.2e-4" },
        .{ "1234.5678", "12345678e-4" },
        .{ "1e400", "10e399" },
        .{ "1e400", "0.1e401" },
        .{ "1e-400", "0.1e-399" },
        .{ "123456789012345678901234567890", "1.2345678901234567890123456789e29" },
        .{ "1e100000000000000000000000000000000", "10e99999999999999999999999999999999" },
        .{ "1e-100000000000000000000000000000000", "10e-100000000000000000000000000000001" },
        .{ "1e0000000000000000000000000000000000002", "100" },
    };
    for (equal) |pair| {
        testing.expect(eql(pair[0], pair[1])) catch |err| {
            std.debug.print("expected equal: {s} {s}\n", .{ pair[0], pair[1] });
            return err;
        };
        try testing.expect(eql(pair[1], pair[0]));
    }
}

test "unequal numbers" {
    const unequal = [_][2][]const u8{
        .{ "0", "1" },
        .{ "1", "-1" },
        .{ "1", "2" },
        .{ "1", "10" },
        .{ "1", "1e1" },
        .{ "1", "0.1" },
        .{ "1.5", "1.05" },
        .{ "12", "21" },
        .{ "1e2", "1e3" },
        .{ "1e-2", "1e2" },
        .{ "0", "1e-999" },
        // These two are the same f64.
        .{ "9007199254740992", "9007199254740993" },
        .{ "123456789012345678901234567890", "123456789012345678901234567891" },
        .{ "1e400", "2e400" },
        .{ "1e400", "1e401" },
        .{ "1e100000000000000000000000000000000", "1e100000000000000000000000000000001" },
        .{ "1e100000000000000000000000000000000", "1e-100000000000000000000000000000000" },
    };
    for (unequal) |pair| {
        testing.expect(!eql(pair[0], pair[1])) catch |err| {
            std.debug.print("expected unequal: {s} {s}\n", .{ pair[0], pair[1] });
            return err;
        };
        try testing.expect(!eql(pair[1], pair[0]));
    }
}

test "agrees with arithmetic on random decimal rewrites" {
    var prng: std.Random.DefaultPrng = .init(6902);
    const random = prng.random();
    var a_buffer: [64]u8 = undefined;
    var b_buffer: [64]u8 = undefined;

    for (0..50_000) |_| {
        const mantissa = random.int(u32);
        const exp = random.intRangeAtMost(i32, -30, 30);
        const a = try std.fmt.bufPrint(&a_buffer, "{d}e{d}", .{ mantissa, exp });

        // Move the decimal exponent into the mantissa as trailing zeros.
        const zeros = random.uintLessThan(u8, 8);
        var b_len = (try std.fmt.bufPrint(&b_buffer, "{d}", .{mantissa})).len;
        @memset(b_buffer[b_len..][0..zeros], '0');
        b_len += zeros;
        const tail = try std.fmt.bufPrint(b_buffer[b_len..], "e{d}", .{exp - zeros});
        try testing.expect(eql(a, b_buffer[0 .. b_len + tail.len]));

        const other = try std.fmt.bufPrint(&b_buffer, "{d}e{d}", .{ mantissa +% 1, exp });
        try testing.expect(!eql(a, other));
    }
}
