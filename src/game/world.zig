const math = @import("math.zig");
const util = @import("util.zig");

pub const Entity = struct {
    p: math.Vec2,
    dp: math.Vec2,

    dim: math.Vec2,

    color: util.Color,
};

ball: Entity,
paddle: Entity,

blocks: [2048]Entity,
block_count: u32,

const World = @This();

pub fn init(world: *World, screen_dims: math.Vec2) void {
    world.* = .{
        .ball = .{
            .p = .init(0, -0.335),
            .dp = .zero,
            .dim = .init(0.02, 0.02),
            .color = .blue,
        },
        .paddle = .{
            .p = .init(0, -0.45),
            .dp = .zero,
            .dim = .init(0.1, 0.01),
            .color = .red,
        },

        .blocks = undefined,
        .block_count = 0,
    };
    world.generateBlocks(.init(.init(-0.5 * screen_dims.x, 0), .init(0.5 * screen_dims.x, 0.45)), .init(0.02, 0.02), 0.005);
}

fn generateBlocks(world: *World, rect: math.Rectangle, dim: math.Vec2, gap: f32) void {
    const align_offset = math.Vec2.init(dim.x, -dim.y).scale(0.5);

    var y: f32 = rect.min.y;
    while (y + dim.y + gap <= rect.max.y) : (y += dim.y + gap) {
        var x: f32 = rect.min.x;
        while (x + dim.x + gap <= rect.max.x) : (x += dim.x + gap) {
            addBlock(world, .{
                .p = math.Vec2.init(x, y).add(align_offset),
                .dp = .zero,
                .dim = dim,
                .color = .green,
            });
        }
    }
}

fn addBlock(world: *World, entity: World.Entity) void {
    util.assert(world.block_count < world.blocks.len, "state blocks OOM");
    world.blocks[world.block_count] = entity;
    world.block_count += 1;
}

pub fn removeBlock(world: *World, block: *World.Entity) void {
    util.assert(world.block_count > 0, "no blocks to remove");
    block.* = world.blocks[world.block_count - 1];
    world.block_count -= 1;
}
