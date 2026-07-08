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

lives: u32,

blocks: [2048]Entity,
block_count: u32,

pub const world_dim = math.Vec2.init(1600, 900);

const World = @This();

pub fn init(world: *World) void {
    world.* = .{
        .ball = .{
            .p = .init(0, -0.335 * world_dim.y),
            .dp = .zero,
            .dim = .init(28, 28),
            .color = .blue,
        },
        .paddle = .{
            .p = .init(0, -0.45 * world_dim.y),
            .dp = .zero,
            .dim = .init(130, 14),
            .color = .red,
        },
        .lives = 5,

        .blocks = undefined,
        .block_count = 0,
    };
    world.generateBlocks(.init(.init(-0.4 * world_dim.x, 0), .init(0.4 * world_dim.x, 0.4 * world_dim.y)), .init(32, 32), 4);
}

fn generateBlocks(world: *World, rect: math.Rectangle, block_dim: math.Vec2, gap: f32) void {
    const align_offset = math.Vec2.init(block_dim.x, -block_dim.y).scale(0.5);
    var y: f32 = rect.min.y;
    while (y + block_dim.y + gap <= rect.max.y) : (y += block_dim.y + gap) {
        var x: f32 = rect.min.x;
        while (x + block_dim.x + gap <= rect.max.x) : (x += block_dim.x + gap) {
            addBlock(world, .{
                .p = math.Vec2.init(x, y).add(align_offset),
                .dp = .zero,
                .dim = block_dim,
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
