const api = @import("game_api");

const sim = @import("sim.zig");
const renderer = @import("renderer.zig");
const assets = @import("assets.zig");
const World = @import("world.zig");

const math = @import("math.zig");
const util = @import("util.zig");
const mem = @import("mem.zig");

const State = struct {
    is_initialized: bool,
    world: World,

    pub fn get(memory: *api.Memory) *State {
        util.assert(memory.permanent_storage_len >= @sizeOf(State), "permanent storage OOM");
        const state: *State = @ptrCast(@alignCast(memory.permanent_storage[0..@sizeOf(State)]));
        if (!state.is_initialized) {
            state.world.init();
            state.is_initialized = true;
        }
        return state;
    }
};

const TransientState = struct {
    is_initialized: bool,

    arena: mem.Arena,
    task_pool: mem.Pool,

    asset_store: *assets.Store,

    flusher: mem.Flusher,

    pub fn get(memory: *api.Memory) *TransientState {
        util.assert(memory.transient_storage_len >= @sizeOf(TransientState), "transient state OOM");
        const state: *TransientState = @ptrCast(@alignCast(memory.transient_storage[0..@sizeOf(TransientState)]));
        if (!state.is_initialized) {
            state.arena = .{
                .memory = memory.transient_storage[@sizeOf(TransientState)..memory.transient_storage_len],
            };
            state.task_pool = .init(&state.arena, 16, 1 * mem.MB);
            state.asset_store = assets.Store.init(&state.arena, &memory.file_ops, &memory.work_queue, &state.task_pool, 5 * mem.MB) catch @panic("asset store init failed");

            state.flusher = .init(&state.arena);
            state.is_initialized = true;
        }
        return state;
    }
};

const input_dp = 750;
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

const ball_dp = math.Vec2.init(450, 450);
pub export fn updateAndRender(screen: *api.Screen, memory: *api.Memory, input: *api.Input) callconv(.c) void {
    const trans_state = TransientState.get(memory);
    defer trans_state.flusher.flush();

    const game_state = State.get(memory);

    game_state.world.paddle.dp = readInput(input);
    if (game_state.world.paddle.dp.x != 0 and game_state.world.ball.dp.lenSq() == 0) {
        game_state.world.ball.dp = ball_dp;
    }

    sim.moveEntity(&game_state.world, &game_state.world.paddle, input.seconds_to_update, true);
    sim.moveEntity(&game_state.world, &game_state.world.ball, input.seconds_to_update, false);

    const screen_dim = math.Vec2.init(@floatFromInt(screen.width), @floatFromInt(screen.height));
    const render_group = renderer.Group.init(
        &trans_state.arena,
        trans_state.asset_store,
        World.world_dim,
        screen_dim,
    );

    render_group.addClear(.black);

    render_group.addBitmap(.initCenterDim(game_state.world.paddle.p, game_state.world.paddle.dim), .paddle, game_state.world.paddle.color);
    render_group.addBitmap(.initCenterDim(game_state.world.ball.p, game_state.world.ball.dim), .puck, game_state.world.ball.color);

    for (game_state.world.blocks[0..game_state.world.block_count]) |block| {
        render_group.addRectangle(.initCenterDim(block.p, block.dim), block.color);
    }

    const life_p = math.Vec2.init(World.world_dim.x * 0.35, World.world_dim.y * 0.5 - 33);
    const life_dim = math.Vec2.init(28, 33);
    const life_gap: f32 = 10;
    for (0..game_state.world.lives) |i| {
        const p = life_p.add(.init((life_dim.x + life_gap) * @as(f32, @floatFromInt(i)), 0));
        render_group.addBitmap(.initCenterDim(p, life_dim), .life, .white);
    }

    const draw_buffer = trans_state.arena.pushStruct(renderer.DrawBuffer);
    draw_buffer.* = .{
        .height = screen.height,
        .width = screen.width,
        .pitch = @intCast(screen.pitch),
        .memory = screen.memory,
    };
    render_group.render(&trans_state.arena, draw_buffer, &memory.work_queue);

    if (game_state.world.block_count == 0 or game_state.world.lives == 0) {
        game_state.world.init();
    }
}

pub export fn outputSound(audio: *api.Audio, memory: *api.Memory) callconv(.c) void {
    _ = memory;
    for (audio.buffer[0..audio.sample_count]) |*sample| {
        sample.* = .{ 0, 0 };
    }
}
