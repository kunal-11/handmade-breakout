const World = @import("world.zig");
const math = @import("math.zig");

const bounce_factor = 1;
const collision_itrs = 4;

pub fn moveEntity(world: *World, entity: *World.Entity, dt: f32, only_screen_collision: bool) void {
    var delta_p = entity.dp.scale(dt);
    for (0..collision_itrs) |_| {
        if (collide(world, entity, delta_p, only_screen_collision)) |collision| {
            if (collision.hit_entity) |hit_entity| {
                if (hit_entity != &world.paddle) {
                    world.removeBlock(hit_entity);
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
    hit_entity: ?*World.Entity,
    normal: math.Vec2,
};

fn collide(world: *World, entity: *World.Entity, delta_p: math.Vec2, only_screen: bool) ?CollisionResponse {
    var t_min: f32 = 1;
    var response: ?CollisionResponse = null;

    if (!only_screen) {
        for (world.blocks[0..world.block_count]) |*block| {
            if (collideEntities(entity, block, delta_p, t_min)) |collision| {
                t_min = collision.t_min;
                response = collision;
            }
        }

        if (collideEntities(entity, &world.paddle, delta_p, t_min)) |collision| {
            t_min = collision.t_min;
            response = collision;
        }
    }

    if (collideEdges(entity, World.world_dim, delta_p, t_min)) |collision| {
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

fn collideEdges(entity: *World.Entity, world_dim: math.Vec2, delta_p: math.Vec2, current_t_min: f32) ?CollisionResponse {
    const minkowski_radius = entity.dim.scale(0.5);
    const world_half_dim = world_dim.scale(0.5);

    const test_walls = [4]TestWall{
        .{
            .p = minkowski_radius.y,
            .radius = world_half_dim.x,
            .delta_p = .init(delta_p.y, delta_p.x),
            .entity_p = .init(entity.p.y + world_half_dim.y, entity.p.x),
            .normal = .init(0, 1),
        },
        .{
            .p = -minkowski_radius.y,
            .radius = world_half_dim.x,
            .delta_p = .init(delta_p.y, delta_p.x),
            .entity_p = .init(entity.p.y - world_half_dim.y, entity.p.x),
            .normal = .init(0, -1),
        },
        .{
            .p = minkowski_radius.x,
            .radius = world_half_dim.y,
            .delta_p = .init(delta_p.x, delta_p.y),
            .entity_p = entity.p.subtract(.init(-world_half_dim.x, 0)),
            .normal = .init(1, 0),
        },
        .{
            .p = -minkowski_radius.x,
            .radius = world_half_dim.y,
            .delta_p = .init(delta_p.x, delta_p.y),
            .entity_p = entity.p.subtract(.init(world_half_dim.x, 0)),
            .normal = .init(-1, 0),
        },
    };

    return collideWalls(&test_walls, current_t_min);
}

fn collideEntities(entity: *World.Entity, test_entity: *World.Entity, delta_p: math.Vec2, current_t_min: f32) ?CollisionResponse {
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
