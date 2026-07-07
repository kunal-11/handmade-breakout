const std = @import("std");

const assets = @import("assets");

const Header = packed struct {
    signature: u16,
    file_size: u32,
    _: u32 = undefined,
    data_offset: u32,
};

const InfoHeader = extern struct {
    size: u32,
    width: u32,
    height: u32,

    planes: u16,
    bits_per_pixel: u16,

    compression: u32,
    image_size: u32,

    _1: i32 = undefined,
    _2: i32 = undefined,
    _3: u32 = undefined,
    _4: u32 = undefined,

    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
    alpha_mask: u32,
};

pub fn parseFile(io: std.Io, gpa: std.mem.Allocator, file_path: []const u8) !assets.LoadedBitmap {
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .unlimited);
    defer gpa.free(contents);
    return parse(gpa, contents);
}

/// Assumes compression is 3 with BI_ALPHABITFIELDS and bottom left as first pixel
/// Premultiplies alpha
fn parse(gpa: std.mem.Allocator, contents: []u8) !assets.LoadedBitmap {
    const info_start = @bitSizeOf(Header) / 8;
    const header = std.mem.bytesToValue(Header, contents[0..info_start]);
    const info_header = std.mem.bytesToValue(InfoHeader, contents[info_start..(info_start + @sizeOf(InfoHeader))]);

    if (header.signature != 0x4D42) return error.SignatureMismatch;
    if (info_header.bits_per_pixel != 32) return error.UnsupportedEncoding;
    if (info_header.compression != 3) return error.UnsupportedCompression;
    if (info_header.planes != 1) return error.UnsupportedPlanes;
    if (@popCount(info_header.red_mask) != 8 or
        @popCount(info_header.alpha_mask) != 8 or
        @popCount(info_header.green_mask) != 8 or
        @popCount(info_header.blue_mask) != 8) return error.InvalidColorMask;

    const memory = try gpa.alloc(u8, @abs(info_header.width * info_header.height) * 4);
    const result: assets.LoadedBitmap = .{
        .height = info_header.height,
        .width = info_header.width,
        .pitch = info_header.width * 4,
        .memory = memory.ptr,
    };

    const color_mask: @Vector(4, u32) = .{
        info_header.blue_mask,
        info_header.green_mask,
        info_header.red_mask,
        info_header.alpha_mask,
    };
    const color_shift: @Vector(4, u5) = @intCast(@ctz(color_mask));

    var input_pixel: []u8 = contents[header.data_offset..];
    for (0..result.height) |y| {
        var result_pixel = memory.ptr + y * result.pitch;
        for (0..result.width) |_| {
            const input: u32 = @bitCast(input_pixel[0..4].*);

            var pixel_f: [4]f32 = undefined;
            inline for (0..4) |c| {
                const color: u32 = (input & color_mask[c]) >> color_shift[c];
                var color_f: f32 = @floatFromInt(color);
                color_f /= 255;
                pixel_f[c] = color_f;
            }

            inline for (0..3) |c| {
                // to linear space
                pixel_f[c] *= pixel_f[c];

                // premultiply alpha
                pixel_f[c] *= pixel_f[3];
            }

            var pixel: [4]u8 = undefined;
            inline for (0..4) |c| {
                const clamped = std.math.clamp(pixel_f[c], 0, 1);
                pixel[c] = @round(clamped * 255);
            }

            result_pixel[0..4].* = pixel;
            input_pixel = input_pixel[4..];
            result_pixel += 4;
        }
    }
    return result;
}
