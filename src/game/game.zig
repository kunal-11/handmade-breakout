const api = @import("game_api");

const renderer = @import("renderer.zig");

const math = @import("math.zig");
const util = @import("util.zig");
const debug = util.debug;

const Entity = struct {
    p: math.Vec2,
    dp: math.Vec2,

    dim: math.Vec2,

    color: util.Color,
};

const State = struct {
    is_initialized: bool,

    ball: ?Entity,
    paddle: Entity,

    blocks: [2048]Entity,
    block_count: u32,

    pub fn get(memory: *api.Memory, screen_dims: math.Vec2) *State {
        debug.assert(memory.permanent_storage_len >= @sizeOf(State), "permanent storage OOM");
        const state: *State = @ptrCast(@alignCast(memory.permanent_storage[0..@sizeOf(State)]));
        if (!state.is_initialized) {
            state.* = .{
                .ball = null,
                .paddle = undefined,

                .blocks = undefined,
                .block_count = 0,

                .is_initialized = true,
            };
            state.paddle = .{
                .p = .init(0, -0.45),
                .dp = .zero,
                .dim = .init(0.1, 0.01),
                .color = .red,
            };
            generateBlocks(state, .init(.init(-0.5 * screen_dims.x, 0), .init(0.5 * screen_dims.x, 0.45)), .init(0.02, 0.02), 0.005);
        }
        return state;
    }
};

fn generateBlocks(state: *State, rect: math.Rectangle, dim: math.Vec2, gap: f32) void {
    const align_offset = math.Vec2.init(dim.x, -dim.y).scale(0.5);

    var y: f32 = rect.min.y;
    while (y + dim.y + gap <= rect.max.y) : (y += dim.y + gap) {
        var x: f32 = rect.min.x;
        while (x + dim.x + gap <= rect.max.x) : (x += dim.x + gap) {
            addBlock(state, .{
                .p = math.Vec2.init(x, y).add(align_offset),
                .dp = .zero,
                .dim = dim,
                .color = .green,
            });
        }
    }
}

fn addBlock(state: *State, entity: Entity) void {
    debug.assert(state.block_count < state.blocks.len, "state blocks OOM");
    state.blocks[state.block_count] = entity;
    state.block_count += 1;
}

fn removeBlock(state: *State, block: *Entity) void {
    debug.assert(state.block_count > 0, "no blocks to remove");
    block.* = state.blocks[state.block_count - 1];
    state.block_count -= 1;
}

const TransientState = struct {
    is_initialized: bool,

    arena: util.Arena,
    flusher: util.Arena.Flusher,

    pub fn get(memory: *api.Memory) *TransientState {
        debug.assert(memory.transient_storage_len >= @sizeOf(TransientState), "transient state OOM");
        const state: *TransientState = @ptrCast(@alignCast(memory.transient_storage[0..@sizeOf(TransientState)]));
        if (!state.is_initialized) {
            state.* = .{
                .arena = .{ .memory = memory.transient_storage[@sizeOf(TransientState)..memory.transient_storage_len] },
                .flusher = undefined,
                .is_initialized = true,
            };
            state.flusher = .init(&state.arena);
        }
        return state;
    }
};

const input_dp = 0.7;
fn readInput(input: *api.Input) math.Vec2 {
    var dp = math.Vec2.zero;

    if (input.controllers[0].move_left.ended_down) {
        dp.x -= input_dp;
    }

    if (input.controllers[0].move_right.ended_down) {
        dp.x += input_dp;
    }

    return dp;
}

const ball_start = Entity{
    .p = .init(0, -0.335),
    .dp = .init(0.4, 0.4),
    .dim = .init(0.02, 0.02),
    .color = .blue,
};

pub export fn updateAndRender(screen: *api.Screen, memory: *api.Memory, input: *api.Input) callconv(.c) void {
    const trans_state = TransientState.get(memory);
    defer trans_state.flusher.flush();

    const screen_height: f32 = @floatFromInt(screen.height);
    const screen_dims = math.Vec2.init(@floatFromInt(screen.width), screen_height).scale(1.0 / screen_height);
    const game_state = State.get(memory, screen_dims);

    game_state.paddle.dp = readInput(input);
    if (game_state.paddle.dp.x != 0 and game_state.ball == null) {
        game_state.ball = ball_start;
    }

    sim.moveEntity(game_state, &game_state.paddle, screen_dims, input.seconds_to_update, true);
    if (game_state.ball) |*ball| {
        sim.moveEntity(game_state, ball, screen_dims, input.seconds_to_update, false);
    }

    const render_group = trans_state.arena.pushStruct(renderer.Group);
    render_group.* = .{ .screen_dims = .init(@floatFromInt(screen.width), @floatFromInt(screen.height)) };

    render_group.addClear(.black);

    render_group.addRectangle(.initCenterDim(game_state.paddle.p, game_state.paddle.dim), game_state.paddle.color);
    if (game_state.ball) |ball| {
        render_group.addRectangle(.initCenterDim(ball.p, ball.dim), ball.color);
    }

    for (game_state.blocks[0..game_state.block_count]) |block| {
        render_group.addRectangle(.initCenterDim(block.p, block.dim), block.color);
    }

    const draw_buffer = renderer.DrawBuffer{
        .height = screen.height,
        .width = screen.width,
        .pitch = @intCast(screen.pitch),
        .memory = screen.memory,
    };
    render_group.render(&draw_buffer);
}

pub export fn outputSound(audio: *api.Audio, memory: *api.Memory) callconv(.c) void {
    _ = memory;
    for (audio.buffer[0..audio.sample_count]) |*sample| {
        sample.* = .{ 0, 0 };
    }
}

const sim = struct {
    const bounce_factor = 1;
    const collision_itrs = 5;

    pub fn moveEntity(state: *State, entity: *Entity, screen_dims: math.Vec2, dt: f32, only_screen_collision: bool) void {
        var delta_p = entity.dp.scale(dt);
        for (0..collision_itrs) |_| {
            if (collide(state, screen_dims, entity, delta_p, only_screen_collision)) |collision| {
                if (collision.hit_entity) |hit_entity| {
                    if (hit_entity != &state.paddle) {
                        removeBlock(state, hit_entity);
                    }
                }

                const collision_t = collision.t_min;
                entity.p = entity.p.add(delta_p.scale(collision_t));
                delta_p = delta_p.scale(1 - collision_t);

                entity.dp = entity.dp.subtract(collision.normal.scale(entity.dp.dot(collision.normal)).scale(1 + bounce_factor));
                delta_p = delta_p.subtract(collision.normal.scale(delta_p.dot(collision.normal)).scale(1 + bounce_factor));
            } else break;
        }
        entity.p = entity.p.add(delta_p);
    }

    const CollisionResponse = struct {
        t_min: f32,
        hit_entity: ?*Entity,
        normal: math.Vec2,
    };

    fn collide(state: *State, screen_dims: math.Vec2, entity: *Entity, delta_p: math.Vec2, only_screen: bool) ?CollisionResponse {
        var t_min: f32 = 1;
        var response: ?CollisionResponse = null;

        if (!only_screen) {
            for (state.blocks[0..state.block_count]) |*block| {
                if (collideEntities(entity, block, delta_p, t_min)) |collision| {
                    t_min = collision.t_min;
                    response = collision;
                }
            }

            if (collideEntities(entity, &state.paddle, delta_p, t_min)) |collision| {
                t_min = collision.t_min;
                response = collision;
            }
        }

        if (collideScreen(entity, screen_dims, delta_p, t_min)) |collision| {
            t_min = collision.t_min;
            response = collision;
        }

        const skin_distance = 0.001;
        if (response) |*r| {
            const delta_dir = -delta_p.dot(r.normal);
            const t_pull_back = skin_distance / delta_dir;
            r.t_min = @max(0, r.t_min - t_pull_back);
        }

        return response;
    }

    const TestWall = struct {
        p: f32,
        radius: f32,

        entity_p: math.Vec2,
        delta_p: math.Vec2,

        normal: math.Vec2,
    };

    fn collideScreen(entity: *Entity, screen_dims: math.Vec2, delta_p: math.Vec2, current_t_min: f32) ?CollisionResponse {
        const minkowski_radius = entity.dim.scale(0.5);
        const screen_half_dim = screen_dims.scale(0.5);

        const test_walls = [4]TestWall{
            .{
                .p = minkowski_radius.y,
                .radius = screen_half_dim.x,
                .delta_p = .init(delta_p.y, delta_p.x),
                .entity_p = .init(entity.p.y + screen_half_dim.y, entity.p.x),
                .normal = .init(0, 1),
            },
            .{
                .p = -minkowski_radius.y,
                .radius = screen_half_dim.x,
                .delta_p = .init(delta_p.y, delta_p.x),
                .entity_p = .init(entity.p.y - screen_half_dim.y, entity.p.x),
                .normal = .init(0, -1),
            },
            .{
                .p = minkowski_radius.x,
                .radius = screen_half_dim.y,
                .delta_p = .init(delta_p.x, delta_p.y),
                .entity_p = entity.p.subtract(.init(-screen_half_dim.x, 0)),
                .normal = .init(1, 0),
            },
            .{
                .p = -minkowski_radius.x,
                .radius = screen_half_dim.y,
                .delta_p = .init(delta_p.x, delta_p.y),
                .entity_p = entity.p.subtract(.init(screen_half_dim.x, 0)),
                .normal = .init(-1, 0),
            },
        };

        return collideWalls(&test_walls, current_t_min);
    }

    fn collideEntities(entity: *Entity, test_entity: *Entity, delta_p: math.Vec2, current_t_min: f32) ?CollisionResponse {
        const expanded_half_dim = test_entity.dim.add(entity.dim).scale(0.5);
        const rel_p = entity.p.subtract(test_entity.p);
        const test_walls = [4]TestWall{
            .{
                .p = -expanded_half_dim.y,
                .radius = expanded_half_dim.x,
                .delta_p = .init(delta_p.y, delta_p.x),
                .entity_p = .init(rel_p.y, rel_p.x),
                .normal = .init(0, -1),
            },
            .{
                .p = expanded_half_dim.y,
                .radius = expanded_half_dim.x,
                .delta_p = .init(delta_p.y, delta_p.x),
                .entity_p = .init(rel_p.y, rel_p.x),
                .normal = .init(0, 1),
            },
            .{
                .p = -expanded_half_dim.x,
                .radius = expanded_half_dim.y,
                .delta_p = delta_p,
                .entity_p = rel_p,
                .normal = .init(-1, 0),
            },
            .{
                .p = expanded_half_dim.x,
                .radius = expanded_half_dim.y,
                .delta_p = delta_p,
                .entity_p = rel_p,
                .normal = .init(1, 0),
            },
        };
        if (collideWalls(&test_walls, current_t_min)) |result| {
            var res = result;
            res.hit_entity = test_entity;
            return res;
        }
        return null;
    }

    fn collideWalls(test_walls: []const TestWall, current_t_min: f32) ?CollisionResponse {
        var test_t_min = current_t_min;
        var test_normal: ?math.Vec2 = null;

        for (test_walls) |test_wall| {
            const internal_normal = if (test_wall.normal.x == 0) test_wall.normal.transpose() else test_wall.normal;
            if (test_wall.delta_p.dot(internal_normal) > 0) continue;

            const hit_t = (test_wall.p - test_wall.entity_p.x) / test_wall.delta_p.x;
            const y = test_wall.entity_p.y + hit_t * test_wall.delta_p.y;

            if (hit_t >= 0 and hit_t < test_t_min and @abs(y) <= test_wall.radius) {
                test_t_min = hit_t;
                test_normal = test_wall.normal;
            }
        }

        if (test_normal) |n| {
            return .{ .t_min = test_t_min, .normal = n, .hit_entity = null };
        }
        return null;
    }
};
