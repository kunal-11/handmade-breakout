const api = @import("game_api");

export fn updateAndRender(screen: *api.Screen, memory: *api.Memory, input: *api.Input) callconv(.c) void {
    _ = screen;
    _ = memory;
    _ = input;
}
export fn outputSound(audio: *api.Audio, memory: *api.Memory) callconv(.c) void {
    _ = audio;
    _ = memory;
}
