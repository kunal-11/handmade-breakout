const api = @import("game_api");

const util = @import("util.zig");
const mem = @import("mem.zig");

pub const format = struct {
    pub const magic: [4]u8 = "PANX".*;
    pub const version: u32 = 0;

    pub const Header = extern struct {
        magic: [4]u8,
        version: u32,

        asset_count: u32,
        _pad: u32 = 0,
    };

    pub const AssetInfo = extern union {
        bitmap: extern struct {
            height: u32,
            width: u32,
        },
    };

    pub const Asset = extern struct {
        info: AssetInfo,
        data_offset: u64,
    };
};

pub const Id = enum(u32) {
    none = 0,

    paddle,
    puck,
    life,

    _,
};

pub const LoadedBitmap = struct {
    height: u32,
    width: u32,
    pitch: u32,
    memory: [*]const u8,
};

pub const Store = struct {
    const Memory = struct {
        data: union {
            empty: void,
            bitmap: LoadedBitmap,
        },
    };

    const Asset = struct {
        stored: format.Asset,
        memory: ?*Memory,
        state: util.Atomic(enum(u8) { unloded, queued, loaded }),
    };

    file_handle: *api.FileOps.Handle,
    read_file: api.FileOps.ReadFile,

    work_q: *api.WorkQueue,
    task_pool: *mem.Pool,

    arena: mem.Arena,
    assets: []Asset,

    pub fn init(arena: *mem.Arena, file_ops: *api.FileOps, work_q: *api.WorkQueue, task_pool: *mem.Pool, size: usize) !*Store {
        const file_handle = file_ops.open_file(.asset) orelse return error.FileOpenFailed;

        var header: format.Header = undefined;
        if (!file_ops.read_file(file_handle, 0, @sizeOf(format.Header), &header)) return error.HeaderLoadFailed;

        if (!mem.eql(&format.magic, &header.magic)) return error.InvalidMagicHeader;
        if (format.version != header.version) return error.InvalidVersionHeader;

        const store = arena.pushStruct(Store);
        store.* = .{
            .file_handle = file_handle,
            .read_file = file_ops.read_file,

            .work_q = work_q,
            .task_pool = task_pool,

            .assets = arena.pushArray(Asset, header.asset_count),
            .arena = .{ .memory = arena.pushArray(u8, size) },
        };

        const flusher = mem.Flusher.init(arena);
        defer flusher.flush();

        const assets = arena.pushArray(format.Asset, header.asset_count);
        if (!file_ops.read_file(file_handle, @sizeOf(format.Header), assets.len * @sizeOf(format.Asset), assets.ptr)) return error.AssetLoadFailed;
        for (0..assets.len) |asset_id| {
            store.assets[asset_id] = .{
                .stored = assets[asset_id],
                .memory = null,
                .state = .init(.unloded),
            };
        }

        return store;
    }

    pub fn getBitmap(store: *Store, id: Id) ?*LoadedBitmap {
        const asset = &store.assets[@intFromEnum(id)];
        if (asset.state.load(.acquire) == .loaded) return &asset.memory.?.data.bitmap;
        return null;
    }

    pub fn loadBitmap(store: *Store, id: Id) void {
        if (id == .none) return;
        const asset = &store.assets[@intFromEnum(id)];
        if (asset.state.load(.acquire) != .unloded) return;

        if (store.task_pool.getSlot()) |slot| {
            const info = &asset.stored.info.bitmap;
            asset.state.store(.queued, .release);

            const memory = store.arena.pushStruct(Memory);
            asset.memory = memory;

            const buf = store.arena.pushArray(u8, info.width * info.height * 4);
            memory.data = .{
                .bitmap = .{
                    .height = info.height,
                    .width = info.width,
                    .pitch = info.width * 4,
                    .memory = buf.ptr,
                },
            };

            const load_info = slot.arena.pushStruct(LoadInfo);
            load_info.* = .{
                .task_slot = slot,
                .read_file = store.read_file,
                .file_handle = store.file_handle,
                .asset = asset,
                .offset = asset.stored.data_offset,
                .buf = buf,
            };
            store.work_q.add_entry(store.work_q.low_priority_queue, &loadWork, load_info);
        }
    }

    const LoadInfo = struct {
        task_slot: *mem.Pool.Slot,

        read_file: api.FileOps.ReadFile,
        file_handle: *api.FileOps.Handle,

        asset: *Asset,
        offset: u64,
        buf: []u8,
    };

    fn loadWork(data: ?*anyopaque) callconv(.c) void {
        const info: *LoadInfo = @ptrCast(@alignCast(data.?));
        defer info.task_slot.free();

        if (info.read_file(info.file_handle, info.offset, info.buf.len, info.buf.ptr)) {
            info.asset.state.store(.loaded, .release);
        } else {
            // TODO: asset memory is leaked here, fix when we have a gpa
            info.asset.state.store(.unloded, .release);
        }
    }
};
