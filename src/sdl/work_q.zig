const std = @import("std");
const game = @import("game_api");

const single_threaded_io = std.Io.Threaded.global_single_threaded.io();

/// Single producer multiple consumer work queue
pub const WorkQueue = struct {
    const buffer_len = 4096;

    last_read_index: std.atomic.Value(u32) = .init(0),
    entries: [buffer_len]Entry = undefined,

    semaphore: *std.Io.Semaphore,
    completed_count: std.atomic.Value(u32) = .init(0),
    write_index: u32 = 1,
    total_count: u32 = 0,

    const Entry = struct {
        data: ?*anyopaque,
        cb: game.WorkQueue.Callback,
    };

    /// single producer
    pub fn addEntry(queue: *WorkQueue, cb: game.WorkQueue.Callback, data: ?*anyopaque) void {
        std.debug.assert(queue.write_index -% queue.last_read_index.load(.acquire) < buffer_len);
        queue.entries[queue.write_index % buffer_len] = .{
            .data = data,
            .cb = cb,
        };
        queue.total_count +%= 1;
        @atomicStore(u32, &queue.write_index, queue.write_index +% 1, .release);
        queue.semaphore.post(single_threaded_io);
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
