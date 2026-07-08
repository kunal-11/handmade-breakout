const std = @import("std");

const assets = @import("assets");
const bmp = @import("bmp.zig");

const State = struct {
    const max_len = 4096;

    const Source = union(enum) {
        bitmap: struct {
            file_path: []const u8,
        },
    };

    assets: [max_len]assets.format.Asset = undefined,
    sources: [max_len]Source = undefined,

    asset_count: u32 = 1,

    fn pushBitmap(state: *State, file_path: []const u8) void {
        std.debug.assert(state.asset_count < max_len);
        state.sources[state.asset_count] = .{ .bitmap = .{ .file_path = file_path } };
        state.asset_count += 1;
    }

    fn outputToFile(state: *State, io: std.Io, gpa: std.mem.Allocator, output_path: []const u8) !void {
        const out = try std.Io.Dir.cwd().createFile(io, output_path, .{});
        defer out.close(io);

        var header = assets.format.Header{
            .magic = assets.format.magic,
            .version = assets.format.version,
            .asset_count = state.asset_count,
        };
        try out.writePositionalAll(io, @ptrCast(&header), 0);

        var write_offset: usize = @sizeOf(assets.format.Header) + state.asset_count * @sizeOf(assets.format.Asset);
        for (1..state.asset_count) |asset_id| {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();

            const asset = &state.assets[asset_id];

            switch (state.sources[asset_id]) {
                .bitmap => |bitmap| {
                    const parsed_bitmap = try bmp.parseFile(io, arena.allocator(), bitmap.file_path);
                    std.debug.assert(parsed_bitmap.pitch == parsed_bitmap.width * 4);

                    asset.info.bitmap.height = parsed_bitmap.height;
                    asset.info.bitmap.width = parsed_bitmap.width;

                    asset.data_offset = write_offset;
                    const bytes = parsed_bitmap.memory[0 .. parsed_bitmap.height * parsed_bitmap.pitch];
                    try out.writePositionalAll(io, bytes, write_offset);
                    write_offset += bytes.len;
                },
            }
        }

        try out.writePositionalAll(io, @ptrCast(state.assets[0..state.asset_count]), @sizeOf(assets.format.Header));
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const state = try arena.create(State);
    state.* = .{};

    state.pushBitmap(".assets/paddle.bmp");
    state.pushBitmap(".assets/puck.bmp");
    state.pushBitmap(".assets/life.bmp");

    try state.outputToFile(init.io, arena, ".assets/assets.hra");
}
