pub const debug = struct {
    pub inline fn assert(check: bool, msg: []const u8) void {
        if (!check) @panic(msg);
    }
};

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub const red = init(1, 0, 0, 1);
    pub const blue = init(0, 0, 1, 1);
    pub const green = init(0, 1, 0, 1);
    pub const black = init(0, 0, 0, 1);

    pub fn init(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub inline fn multiplyAlpha(color: Color) Color {
        return .{
            .r = color.r * color.a,
            .g = color.g * color.a,
            .b = color.b * color.a,
            .a = color.a,
        };
    }

    pub fn toPackedU32(color: Color) u32 {
        return @bitCast([4]u8{
            @round(color.r * 255),
            @round(color.g * 255),
            @round(color.b * 255),
            @round(color.a * 255),
        });
    }

    pub fn srgbToLinear(color: Color) Color {
        return .{
            .r = color.r * color.r,
            .g = color.g * color.g,
            .b = color.b * color.b,
            .a = color.a,
        };
    }
};

pub const Arena = struct {
    memory: []u8,
    used: usize = 0,

    pub inline fn pushStruct(arena: *Arena, T: type) *T {
        return @ptrCast(arena.pushBytes(@sizeOf(T), @alignOf(T)));
    }

    pub inline fn pushArray(arena: *Arena, T: type, len: usize) []T {
        return @ptrCast(arena.pushBytes(@sizeOf(T) * len, @alignOf(T)));
    }

    pub inline fn pushArrayAligned(arena: *Arena, T: type, len: usize, comptime alignment: usize) []align(alignment) T {
        return @ptrCast(arena.pushBytes(@sizeOf(T) * len, alignment));
    }

    inline fn pushBytes(arena: *Arena, len: usize, comptime alignment: usize) []align(alignment) u8 {
        const offset = alignOffset(&arena.memory[arena.used], alignment);
        arena.used += offset + len;
        return @alignCast(arena.memory[arena.used - len .. arena.used]);
    }

    inline fn alignOffset(ptr: *anyopaque, alignment: usize) usize {
        const aligned_ptr = alignUp(@intFromPtr(ptr), alignment);
        return aligned_ptr - @intFromPtr(ptr);
    }

    inline fn alignUp(val: usize, alignment: usize) usize {
        return alignDown(val + alignment - 1, alignment);
    }

    inline fn alignDown(val: usize, alignment: usize) usize {
        if (alignment == 0 or alignment & (alignment - 1) != 0) @compileError("alignment not a power of 2");
        return val & ~(alignment - 1);
    }

    pub const Flusher = struct {
        arena: *Arena,
        marker: usize,

        pub fn init(arena: *Arena) Flusher {
            return .{ .arena = arena, .marker = arena.used };
        }

        pub fn flush(flusher: Flusher) void {
            flusher.arena.used = flusher.marker;
        }
    };
};
