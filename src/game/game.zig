const api = @import("game_api");

const sim = @import("sim.zig");
const renderer = @import("renderer.zig");
const World = @import("world.zig");

const math = @import("math.zig");
const util = @import("util.zig");

const State = struct {
    is_initialized: bool,
    world: World,

    pub fn get(memory: *api.Memory, screen_dims: math.Vec2) *State {
        util.assert(memory.permanent_storage_len >= @sizeOf(State), "permanent storage OOM");
        const state: *State = @ptrCast(@alignCast(memory.permanent_storage[0..@sizeOf(State)]));
        if (!state.is_initialized) {
            state.world.init(screen_dims);
            state.is_initialized = true;
        }
        return state;
    }
};

const TransientState = struct {
    is_initialized: bool,

    arena: util.Arena,
    flusher: util.Arena.Flusher,

    pub fn get(memory: *api.Memory) *TransientState {
        util.assert(memory.transient_storage_len >= @sizeOf(TransientState), "transient state OOM");
        const state: *TransientState = @ptrCast(@alignCast(memory.transient_storage[0..@sizeOf(TransientState)]));
        if (!state.is_initialized) {
            state.arena = .{
                .memory = memory.transient_storage[@sizeOf(TransientState)..memory.transient_storage_len],
            };
            state.flusher = .init(&state.arena);
            state.is_initialized = true;
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

const ball_dp = math.Vec2.init(0.4, 0.4);
pub export fn updateAndRender(screen: *api.Screen, memory: *api.Memory, input: *api.Input) callconv(.c) void {
    const trans_state = TransientState.get(memory);
    defer trans_state.flusher.flush();

    const screen_height: f32 = @floatFromInt(screen.height);
    const screen_dims = math.Vec2.init(@floatFromInt(screen.width), screen_height).scale(1.0 / screen_height);
    const game_state = State.get(memory, screen_dims);

    game_state.world.paddle.dp = readInput(input);
    if (game_state.world.paddle.dp.x != 0 and game_state.world.ball.dp.lenSq() == 0) {
        game_state.world.ball.dp = ball_dp;
    }

    sim.moveEntity(&game_state.world, &game_state.world.paddle, screen_dims, input.seconds_to_update, true);
    sim.moveEntity(&game_state.world, &game_state.world.ball, screen_dims, input.seconds_to_update, false);

    const render_group = trans_state.arena.pushStruct(renderer.Group);
    render_group.* = .{ .screen_dims = .init(@floatFromInt(screen.width), @floatFromInt(screen.height)) };

    render_group.addClear(.black);

    render_group.addRectangle(.initCenterDim(game_state.world.paddle.p, game_state.world.paddle.dim), game_state.world.paddle.color);
    render_group.addRectangle(.initCenterDim(game_state.world.ball.p, game_state.world.ball.dim), game_state.world.ball.color);

    for (game_state.world.blocks[0..game_state.world.block_count]) |block| {
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
