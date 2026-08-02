//! Color conversion between normalized sRGB and OKLCH.

const std = @import("std");

/// A gamma-encoded sRGB color with channels conventionally in `[0, 1]`.
pub const Rgb = struct {
    r: f64,
    g: f64,
    b: f64,

    /// Convert normalized, gamma-encoded sRGB to OKLCH.
    pub fn toOklch(rgb: Rgb) Oklch {
        std.debug.assert(std.math.isFinite(rgb.r));
        std.debug.assert(std.math.isFinite(rgb.g));
        std.debug.assert(std.math.isFinite(rgb.b));

        const linear = LinearRgb{
            .r = decodeSrgb(rgb.r),
            .g = decodeSrgb(rgb.g),
            .b = decodeSrgb(rgb.b),
        };
        return Oklch.fromLab(linear.toLab());
    }
};

/// An OKLCH color with finite unit lightness, chroma, and hue in degrees.
pub const Oklch = struct {
    l: f64,
    c: f64,
    h: f64,

    /// Convert OKLCH to normalized, gamma-encoded sRGB.
    ///
    /// Out-of-gamut colors are mapped using the CSS Color 4 binary-search
    /// algorithm with local MINDE. Its search holds lightness and hue constant
    /// while reducing chroma; the final local clip may change them by less than
    /// one just-noticeable difference.
    pub fn toRgb(oklch: Oklch) Rgb {
        std.debug.assert(std.math.isFinite(oklch.l));
        std.debug.assert(std.math.isFinite(oklch.c));
        std.debug.assert(std.math.isFinite(oklch.h));

        if (oklch.l >= 1.0) return .{ .r = 1.0, .g = 1.0, .b = 1.0 };
        if (oklch.l <= 0.0) return .{ .r = 0.0, .g = 0.0, .b = 0.0 };

        var current = oklch;
        current.c = @max(0.0, current.c);

        var linear = LinearRgb.fromLab(current.toLab());
        if (linear.isInGamut()) return linear.toRgb();

        var clipped = linear.clipped();
        if (deltaE(current.toLab(), clipped.toLab()) < jnd) {
            return clipped.toRgb();
        }

        var min: f64 = 0.0;
        var max = current.c;
        var min_in_gamut = true;
        var iterations: usize = 0;

        while (max - min > gamut_epsilon and iterations < 64) : (iterations += 1) {
            const chroma = (min + max) / 2.0;
            current.c = chroma;
            linear = LinearRgb.fromLab(current.toLab());

            if (min_in_gamut and linear.isInGamut()) {
                min = chroma;
                continue;
            }

            clipped = linear.clipped();
            const difference = deltaE(current.toLab(), clipped.toLab());
            if (difference < jnd) {
                if (jnd - difference < gamut_epsilon) return clipped.toRgb();

                min_in_gamut = false;
                min = chroma;
            } else {
                max = chroma;
            }
        }

        return clipped.toRgb();
    }

    fn fromLab(lab: Lab) Oklch {
        const chroma = @sqrt(lab.a * lab.a + lab.b * lab.b);
        var hue = std.math.atan2(lab.b, lab.a) * radians_to_degrees;
        if (hue < 0.0) hue += 360.0;

        return .{ .l = lab.l, .c = chroma, .h = hue };
    }

    fn toLab(oklch: Oklch) Lab {
        const hue = oklch.h * degrees_to_radians;
        return .{
            .l = oklch.l,
            .a = oklch.c * @cos(hue),
            .b = oklch.c * @sin(hue),
        };
    }
};

const Lab = struct {
    l: f64,
    a: f64,
    b: f64,
};

const LinearRgb = struct {
    r: f64,
    g: f64,
    b: f64,

    fn fromLab(lab: Lab) LinearRgb {
        const l_root = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b;
        const m_root = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b;
        const s_root = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b;

        const l = l_root * l_root * l_root;
        const m = m_root * m_root * m_root;
        const s = s_root * s_root * s_root;

        return .{
            .r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            .g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            .b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
        };
    }

    fn toLab(rgb: LinearRgb) Lab {
        const l = 0.4122214708 * rgb.r + 0.5363325363 * rgb.g + 0.0514459929 * rgb.b;
        const m = 0.2119034982 * rgb.r + 0.6806995451 * rgb.g + 0.1073969566 * rgb.b;
        const s = 0.0883024619 * rgb.r + 0.2817188376 * rgb.g + 0.6299787005 * rgb.b;

        const l_root = std.math.cbrt(l);
        const m_root = std.math.cbrt(m);
        const s_root = std.math.cbrt(s);

        return .{
            .l = 0.2104542553 * l_root + 0.7936177850 * m_root - 0.0040720468 * s_root,
            .a = 1.9779984951 * l_root - 2.4285922050 * m_root + 0.4505937099 * s_root,
            .b = 0.0259040371 * l_root + 0.7827717662 * m_root - 0.8086757660 * s_root,
        };
    }

    fn isInGamut(rgb: LinearRgb) bool {
        return rgb.r >= 0.0 and rgb.r <= 1.0 and
            rgb.g >= 0.0 and rgb.g <= 1.0 and
            rgb.b >= 0.0 and rgb.b <= 1.0;
    }

    fn clipped(rgb: LinearRgb) LinearRgb {
        return .{
            .r = std.math.clamp(rgb.r, 0.0, 1.0),
            .g = std.math.clamp(rgb.g, 0.0, 1.0),
            .b = std.math.clamp(rgb.b, 0.0, 1.0),
        };
    }

    fn toRgb(rgb: LinearRgb) Rgb {
        return .{
            .r = std.math.clamp(encodeSrgb(rgb.r), 0.0, 1.0),
            .g = std.math.clamp(encodeSrgb(rgb.g), 0.0, 1.0),
            .b = std.math.clamp(encodeSrgb(rgb.b), 0.0, 1.0),
        };
    }
};

const jnd: f64 = 0.02;
const gamut_epsilon: f64 = 0.0001;
const degrees_to_radians: f64 = std.math.pi / 180.0;
const radians_to_degrees: f64 = 180.0 / std.math.pi;

fn decodeSrgb(channel: f64) f64 {
    if (channel <= 0.04045) return channel / 12.92;
    return std.math.pow(f64, (channel + 0.055) / 1.055, 2.4);
}

fn encodeSrgb(channel: f64) f64 {
    if (channel <= 0.0031308) return 12.92 * channel;
    return 1.055 * std.math.pow(f64, channel, 1.0 / 2.4) - 0.055;
}

fn deltaE(first: Lab, second: Lab) f64 {
    const delta_l = first.l - second.l;
    const delta_a = first.a - second.a;
    const delta_b = first.b - second.b;
    return @sqrt(delta_l * delta_l + delta_a * delta_a + delta_b * delta_b);
}

fn expectRgbApprox(expected: Rgb, actual: Rgb, tolerance: f64) !void {
    try std.testing.expectApproxEqAbs(expected.r, actual.r, tolerance);
    try std.testing.expectApproxEqAbs(expected.g, actual.g, tolerance);
    try std.testing.expectApproxEqAbs(expected.b, actual.b, tolerance);
}

test "sRGB primaries convert to OKLCH reference values" {
    const red = (Rgb{ .r = 1.0, .g = 0.0, .b = 0.0 }).toOklch();
    try std.testing.expectApproxEqAbs(0.627955, red.l, 0.000001);
    try std.testing.expectApproxEqAbs(0.257683, red.c, 0.000001);
    try std.testing.expectApproxEqAbs(29.2339, red.h, 0.0001);

    const green = (Rgb{ .r = 0.0, .g = 1.0, .b = 0.0 }).toOklch();
    try std.testing.expectApproxEqAbs(0.866440, green.l, 0.000001);
    try std.testing.expectApproxEqAbs(0.294827, green.c, 0.000001);
    try std.testing.expectApproxEqAbs(142.4953, green.h, 0.0001);

    const blue = (Rgb{ .r = 0.0, .g = 0.0, .b = 1.0 }).toOklch();
    try std.testing.expectApproxEqAbs(0.452014, blue.l, 0.000001);
    try std.testing.expectApproxEqAbs(0.313214, blue.c, 0.000001);
    try std.testing.expectApproxEqAbs(264.0520, blue.h, 0.0001);
}

test "sRGB colors round trip through OKLCH" {
    const colors = [_]Rgb{
        .{ .r = 0.0, .g = 0.0, .b = 0.0 },
        .{ .r = 1.0, .g = 1.0, .b = 1.0 },
        .{ .r = 1.0, .g = 0.0, .b = 0.0 },
        .{ .r = 0.0, .g = 1.0, .b = 0.0 },
        .{ .r = 0.0, .g = 0.0, .b = 1.0 },
        .{ .r = 0.4, .g = 0.2, .b = 0.6 },
        .{ .r = 0.03, .g = 0.5, .b = 0.95 },
    };

    for (colors) |rgb| {
        try expectRgbApprox(rgb, rgb.toOklch().toRgb(), 0.000001);
    }
}

test "out-of-gamut OKLCH maps into sRGB without changing hue perceptibly" {
    const origin = Oklch{ .l = 0.7, .c = 0.4, .h = 40.0 };
    const mapped_rgb = origin.toRgb();

    try std.testing.expect(mapped_rgb.r >= 0.0 and mapped_rgb.r <= 1.0);
    try std.testing.expect(mapped_rgb.g >= 0.0 and mapped_rgb.g <= 1.0);
    try std.testing.expect(mapped_rgb.b >= 0.0 and mapped_rgb.b <= 1.0);

    const mapped = mapped_rgb.toOklch();
    try std.testing.expectApproxEqAbs(origin.l, mapped.l, jnd);
    try std.testing.expectApproxEqAbs(origin.h, mapped.h, 1.0);
    try std.testing.expect(mapped.c < origin.c);
}

test "out-of-range OKLCH lightness maps to black or white" {
    try expectRgbApprox(
        .{ .r = 0.0, .g = 0.0, .b = 0.0 },
        (Oklch{ .l = -0.1, .c = 0.4, .h = 20.0 }).toRgb(),
        0.0,
    );
    try expectRgbApprox(
        .{ .r = 1.0, .g = 1.0, .b = 1.0 },
        (Oklch{ .l = 1.1, .c = 0.4, .h = 20.0 }).toRgb(),
        0.0,
    );
}
