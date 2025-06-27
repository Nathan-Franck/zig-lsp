const std = @import("std");

const node_graph = @import("../node_graph.zig");
const utils = @import("../utils.zig");
const game = @import("../game.zig");

const Allocator = std.mem.Allocator;

const Dirtyable = node_graph.Dirtyable;
const DirtyableFields = node_graph.DirtyableFields;
const Runtime = game.types.Runtime;
const Vec4 = utils.Vec4;
const Mat = utils.Mat;
const Mesh = utils.types.Mesh;

const types = game.types;
const nodes = game.nodes;
const Model = types.Rendering.Model;
const MeshUpdate = types.Rendering.MeshUpdate;
const InstancesUpdate = types.Rendering.InstancesUpdate;

pub const GameGraph = Runtime.build(struct {
    pub const State = struct {
        orbit: nodes.Orbit.State,
        bike: nodes.Bike.State,

        pub const default: @This() = .{
            .orbit = .default,
            .bike = .default,
        };
    };

    pub fn update(
        rt: *Runtime,
        frontend: anytype,
        state: DirtyableFields(State),
    ) DirtyableFields(State) {
        const resources = rt.node(@src(), nodes.Resources, .{});

        const light = rt.node(@src(), nodes.Light, .{});

        const timing = rt.node(@src(), nodes.Timing, .{
            .time = frontend.poll(.time),
        });
        const bike = rt.node(@src(), nodes.Bike, .{
            .state = state.bike,
            .time = timing.physics,
            .model_transforms = resources.model_transforms,
            .bounce = frontend.poll(.bounce),
            .stamps = resources.stamps,
        });
        frontend.submit(.{
            .sun = light.sun,
        });

        const orbit = rt.node(@src(), nodes.Orbit, .{
            .state = state.orbit,
            .timing = timing.realtime,
            .render_resolution = frontend.poll(.render_resolution),
            .orbit_speed = frontend.poll(.orbit_speed),
            .input = frontend.poll(.input),
            .player_settings = frontend.poll(.player_settings),
            .stamps = resources.stamps,
        });

        const terrain_chunks = rt.node(@src(), nodes.TerrainChunks, .{
            .camera_position = orbit.camera_position,
            .stamps = resources.stamps,
        });

        const mesh_update_sources = &.{
            terrain_chunks.mesh_updates,
            rt.node(@src(), nodes.AnimatedMeshes, .{
                .timing = timing.low_update,
                .models = resources.models,
            }).updates,
            rt.pipe(@src(), resources.models, struct {
                pub fn process(arena: Allocator, input: []const Model) ![]const MeshUpdate {
                    var output: std.ArrayList(MeshUpdate) = .init(arena);
                    for (input) |model| {
                        var meshes: std.ArrayList(Mesh) = .init(arena);
                        for (model.meshes) |mesh|
                            switch (mesh) {
                                .subdiv => {},
                                .mesh => |m| try meshes.append(m),
                            };
                        if (meshes.items.len > 0)
                            try output.append(.{ .renderer = .{ .model = model.id }, .meshes = meshes.items });
                    }
                    return output.items;
                }
            }),
        };
        const mesh_update_candidates = rt.node(@src(), concat(MeshUpdate), mesh_update_sources).outputs;
        const mesh_updates = concatChanged(rt.frame_arena.allocator(), MeshUpdate, mesh_update_sources);
        const instance_sources = &.{
            terrain_chunks.instance_updates,
            bike.model_instances,
        };
        const all_model_instances = rt.node(@src(), concat(InstancesUpdate), instance_sources).outputs;

        const mesh_bounds = rt.node(@src(), nodes.MeshBounds, .{ .updates = mesh_update_candidates }).mesh_bounds;

        const culling = rt.node(@src(), nodes.FrustumCulling, .{
            .camera_world_matrix = orbit.world_matrix,
        });
        _ = culling;

        const shadow = rt.node(@src(), nodes.Shadow, .{
            .light = light.sun,
            .model_bounds = mesh_bounds,
            .all_models = mesh_update_candidates,
            .changed_models = mesh_updates,
            .all_model_instances = all_model_instances,
        });

        frontend.submit(.{
            .models = mesh_updates,
            .model_instances = concatChanged(rt.frame_arena.allocator(), InstancesUpdate, instance_sources),
            .shadow_updates = shadow.updates,
        });

        frontend.submit(.{
            .lock_mouse = orbit.lock_mouse,
            .exit = orbit.exit,
            .world_matrix = orbit.world_matrix,
            .camera_position = orbit.camera_position,
            .screen_space_mesh = rt.node(@src(), nodes.ScreenspaceMesh, .{
                .camera_position = orbit.camera_position,
                .world_matrix = orbit.world_matrix,
            }).screen_space_mesh,
        });

        return .{
            .bike = bike.state,
            .orbit = orbit.state,
        };
    }
});

/// take a bunch of Dirtyable inputs and put them together, only including dirty ones
pub fn concatChanged(arena: Allocator, T: type, inputs: []const Dirtyable([]const T)) Dirtyable([]const T) {
    for (inputs) |input| {
        if (input.is_dirty) break;
    } else return .{
        .raw = &.{},
        .previous_raw = &.{},
        .is_dirty = false,
    };
    var to_concat: std.ArrayList([]const T) = .init(arena);
    for (inputs) |input| {
        if (input.is_dirty) {
            to_concat.append(input.raw) catch unreachable;
        }
    }
    return .{
        .raw = std.mem.concat(arena, T, to_concat.items) catch unreachable,
        .previous_raw = &.{},
        .is_dirty = true,
    };
}

/// Concat wrapped in a node
pub fn concat(T: type) type {
    return struct {
        pub fn update(
            _: *@This(),
            arena: Allocator,
            inputs: []const []const T,
        ) struct { outputs: []const T } {
            return .{
                .outputs = std.mem.concat(arena, T, inputs) catch unreachable,
            };
        }
    };
}
