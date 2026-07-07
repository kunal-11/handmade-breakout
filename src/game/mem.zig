const util = @import("util.zig");

pub const KB = 1 << 10;
pub const MB = 1 << 20;
pub const GB = 1 << 30;

pub inline fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |v1, v2| {
        if (v1 != v2) return false;
    }
    return true;
}

inline fn alignUp(val: usize, alignment: usize) usize {
    return alignDown(val + alignment - 1, alignment);
}

inline fn alignDown(val: usize, alignment: usize) usize {
    if (alignment == 0 or alignment & (alignment - 1) != 0) @compileError("alignment not a power of 2");
    return val & ~(alignment - 1);
}

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
        const ptr = @intFromPtr(&arena.memory[arena.used]);
        const align_offset = alignUp(ptr, alignment) - ptr;

        arena.used += align_offset + len;
        util.assert(arena.used <= arena.memory.len, "arena OOM!");
        return @alignCast(arena.memory[arena.used - len .. arena.used]);
    }
};

pub const Flusher = struct {
    arena: *Arena,
    marker: usize,

    pub inline fn init(arena: *Arena) Flusher {
        return .{ .arena = arena, .marker = arena.used };
    }

    pub inline fn flush(flusher: Flusher) void {
        flusher.arena.used = flusher.marker;
    }
};

pub const Pool = struct {
    pub const Slot = struct {
        arena: Arena,
        status: util.Atomic(enum(u8) { free, used }),

        pub fn free(slot: *Slot) void {
            util.assert(slot.status.load(.acquire) == .used, "double free pool slot");
            slot.arena.used = 0;
            slot.status.store(.free, .release);
        }
    };

    slots: []Slot,

    pub fn init(arena: *Arena, slot_count: u32, slot_size: usize) Pool {
        const slots = arena.pushArray(Slot, slot_count);
        for (slots) |*slot| {
            slot.* = .{
                .arena = .{ .memory = arena.pushArray(u8, slot_size) },
                .status = .init(.free),
            };
        }
        return .{ .slots = slots };
    }

    // single threded, returns null if no slot found
    pub fn getSlot(pool: Pool) ?*Slot {
        for (pool.slots) |*slot| {
            if (slot.status.load(.acquire) == .free) {
                slot.status.store(.used, .release);
                return slot;
            }
        }
        return null;
    }
};
