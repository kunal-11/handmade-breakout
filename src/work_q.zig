const std = @import("std");
const api = @import("game_api");
const builtin = @import("builtin");

pub const Signal = struct {
    io: std.Io,
    counter: std.atomic.Value(u32),

    pub fn incrementNotify(signal: *Signal) void {
        _ = signal.counter.fetchAdd(1, .acq_rel);
        if (builtin.cpu.arch.isWasm()) {
            comptime std.debug.assert(builtin.cpu.has(.wasm, .atomics));
            const wake_count: i32 = 1;
            _ = asm volatile (
                \\local.get %[ptr]
                \\local.get %[wake]
                \\memory.atomic.notify 0
                \\local.set %[ret]
                : [ret] "=r" (-> u32),
                : [ptr] "r" (&signal.counter.raw),
                  [wake] "r" (wake_count),
            );
        } else {
            signal.io.futexWake(u32, &signal.counter.raw, 1);
        }
    }

    pub fn wait(signal: *Signal, expect: u32) void {
        if (builtin.cpu.arch.isWasm()) {
            comptime std.debug.assert(builtin.cpu.has(.wasm, .atomics));
            const timeout: i64 = -1;
            const signed_expect: i32 = @bitCast(expect);
            _ = asm volatile (
                \\local.get %[ptr]
                \\local.get %[expected]
                \\local.get %[timeout]
                \\memory.atomic.wait32 0
                \\local.set %[ret]
                : [ret] "=r" (-> u32),
                : [ptr] "r" (&signal.counter.raw),
                  [expected] "r" (signed_expect),
                  [timeout] "r" (timeout),
            );
        } else {
            signal.io.futexWaitUncancelable(u32, &signal.counter.raw, expect);
        }
    }
};

/// Single producer multiple consumer work queue
pub const WorkQueue = struct {
    const buffer_len = 4096;

    last_read_index: std.atomic.Value(u32) = .init(0),
    entries: [buffer_len]Entry = undefined,

    signal: *Signal,

    completed_count: std.atomic.Value(u32) = .init(0),
    write_index: u32 = 1,
    total_count: u32 = 0,

    const Entry = struct {
        data: ?*anyopaque,
        cb: api.WorkQueue.Callback,
    };

    /// single producer
    pub fn addEntry(queue: *WorkQueue, cb: api.WorkQueue.Callback, data: ?*anyopaque) void {
        std.debug.assert(queue.write_index -% queue.last_read_index.load(.acquire) < buffer_len);
        queue.entries[queue.write_index % buffer_len] = .{
            .data = data,
            .cb = cb,
        };
        queue.total_count +%= 1;
        @atomicStore(u32, &queue.write_index, queue.write_index +% 1, .release);
        queue.signal.incrementNotify();
    }

    /// returns true if no entries are remaining
    pub fn doNextEntry(queue: *WorkQueue) bool {
        const original_last_read_index = queue.last_read_index.load(.acquire);
        const next_read_index = original_last_read_index +% 1;
        if (next_read_index != @atomicLoad(u32, &queue.write_index, .acquire)) {
            const entry = queue.entries[next_read_index % buffer_len];
            if (queue.last_read_index.cmpxchgWeak(original_last_read_index, next_read_index, .acq_rel, .acquire) == null) {
                entry.cb(entry.data);
                _ = queue.completed_count.fetchAdd(1, .acq_rel);
            }
            return false;
        } else return true;
    }

    /// only producer is allowed to call
    pub fn completeAllWork(queue: *WorkQueue) void {
        while (queue.completed_count.load(.acquire) != queue.total_count) {
            _ = queue.doNextEntry();
        }
    }
};

pub fn addEntryShim(queue: *api.WorkQueue.Queue, cb: api.WorkQueue.Callback, data: ?*anyopaque) callconv(.c) void {
    const work_queue: *WorkQueue = @ptrCast(@alignCast(queue));
    work_queue.addEntry(cb, data);
}

pub fn completeAllWorkShim(queue: *api.WorkQueue.Queue) callconv(.c) void {
    const work_queue: *WorkQueue = @ptrCast(@alignCast(queue));
    work_queue.completeAllWork();
}
