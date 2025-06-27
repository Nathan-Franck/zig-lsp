const std = @import("std");
const zmath = @import("zmath");

const utils = @import("../utils.zig");
const utils_node = @import("../node_graph.zig").utils;
const Allocator = std.mem.Allocator;

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

fn ParamsToNodeProps(Node: type) type {
    const @"fn" = @TypeOf(Node.update);
    const params = @typeInfo(@"fn").@"fn".params;
    return params[2].type.?;
}

const InputType = struct { T: type, alignment: comptime_int };
fn NodeInputFromProp(T: type) InputType {
    const default = InputType{ .T = T, .alignment = @alignOf(T) };
    return switch (@typeInfo(T)) {
        .@"struct" => blk: {
            if (utils_node.queryable.getSourceOrNull(T)) |t| {
                break :blk .{ .T = t, .alignment = @alignOf(t) };
            } else {
                break :blk default;
            }
        },
        .pointer => |pointer| if (!pointer.is_const) switch (pointer.size) {
            else => default,
            .one => .{ .T = pointer.child, .alignment = @alignOf(pointer.child) },
            .slice => .{ .T = []const pointer.child, .alignment = @alignOf(pointer.child) },
        } else default,
        else => default,
    };
}

fn ParamsToPipeInput(Pipe: type) type {
    const @"fn" = @TypeOf(Pipe.process);
    const params = @typeInfo(@"fn").@"fn".params;
    return params[1].type.?;
}

fn PipeInput(Pipe: type) type {
    const raw_input = ParamsToPipeInput(Pipe);
    return Dirtyable(raw_input);
}

fn NodeInputs(Node: type) type {
    const raw_props = ParamsToNodeProps(Node);
    switch (@typeInfo(raw_props)) {
        else => @compileError("Unhandled props type!"),
        .pointer => |p| switch (p.size) {
            else => @compileError("Unhandled props type!"),
            .slice => {
                const node_input = NodeInputFromProp(p.child);
                return @Type(std.builtin.Type{ .pointer = .{
                    .size = .slice,
                    .is_const = true,
                    .alignment = node_input.alignment,
                    .child = Dirtyable(node_input.T),
                    .address_space = p.address_space,
                    .is_volatile = p.is_volatile,
                    .is_allowzero = p.is_allowzero,
                    .sentinel_ptr = p.sentinel_ptr,
                } });
            },
        },
        .@"struct" => |s| {
            var new_fields: []const std.builtin.Type.StructField = &.{};
            for (s.fields) |field| {
                const node_input = NodeInputFromProp(field.type);
                new_fields = new_fields ++ .{std.builtin.Type.StructField{
                    .name = field.name,
                    .type = Dirtyable(node_input.T),
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = node_input.alignment,
                }};
            }
            return @Type(std.builtin.Type{ .@"struct" = .{
                .layout = .auto,
                .fields = new_fields,
                .decls = &.{},
                .is_tuple = false,
            } });
        },
    }
}

fn NodeOutputs(Node: type) type {
    const @"fn" = Node.update;
    const fn_return = @typeInfo(@TypeOf(@"fn")).@"fn".return_type.?;
    const raw_return = switch (@typeInfo(fn_return)) {
        else => fn_return,
        .error_union => |e| e.payload,
    };
    return DirtyableFields(raw_return);
}

fn PipeOutput(Pipe: type) type {
    const @"fn" = Pipe.process;
    const fn_return = @typeInfo(@TypeOf(@"fn")).@"fn".return_type.?;
    const raw_return = switch (@typeInfo(fn_return)) {
        else => fn_return,
        .error_union => |e| e.payload,
    };
    return raw_return;
}

pub fn Dirtyable(T: type) type {
    return struct {
        raw: T,
        previous_raw: ?T,
        is_dirty: bool,
        fn set(self: *@This(), value: T, previous_value: T) void {
            self.is_dirty = true;
            self.previous_raw = previous_value;
            self.raw = value;
        }
    };
}

pub fn DirtyableFields(T: type) type {
    var new_fields: []const std.builtin.Type.StructField = &.{};
    const fields = switch (@typeInfo(T)) {
        .@"struct" => |s| s.fields,
        .@"union" => |u| u.fields,
        else => @compileError("Unsupported " ++ @typeName(T)),
    };
    for (fields) |field| {
        new_fields = new_fields ++ .{std.builtin.Type.StructField{
            .name = field.name,
            .type = Dirtyable(field.type),
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(field.type),
        }};
    }
    return @Type(std.builtin.Type{ .@"struct" = .{
        .layout = .auto,
        .fields = new_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

pub fn StructFromUnion(T: type) type {
    var new_fields: []const std.builtin.Type.StructField = &.{};
    const fields = switch (@typeInfo(T)) {
        .@"struct" => |s| s.fields,
        .@"union" => |u| u.fields,
        else => @compileError("Unsupported " ++ @typeName(T)),
    };
    for (fields) |field| {
        new_fields = new_fields ++ .{std.builtin.Type.StructField{
            .name = field.name,
            .type = field.type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(field.type),
        }};
    }
    return @Type(std.builtin.Type{ .@"struct" = .{
        .layout = .auto,
        .fields = new_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

pub fn Runtime(_Inputs: type, _Outputs: type) type {
    return struct {
        const RuntimeSelf = @This();
        pub const Inputs = _Inputs;
        pub const Outputs = _Outputs;
        pub const FrontendPollFn = fn (frontend: *anyopaque, field_tag: *const std.meta.FieldEnum(Inputs)) callconv(.C) *const Inputs;
        pub const FrontendSubmitFn = fn (frontend: *anyopaque, value: [*]const Outputs, value_len: usize) callconv(.C) void;

        frame_arena: utils.DoubleBufferedArena,
        allocator: std.mem.Allocator,
        node_states: std.StringHashMap(NodeState),

        pub fn pipe(
            self: *@This(),
            comptime src: std.builtin.SourceLocation,
            dirtyable_input: anytype,
            Pipe: type,
        ) Dirtyable(PipeOutput(Pipe)) {
            if (@TypeOf(dirtyable_input) != PipeInput(Pipe)) @compileError("dirtyable_input must be the pipe's input type");

            const result = self.node(src, struct {
                fn update(
                    _: *@This(),
                    arena: std.mem.Allocator,
                    props: struct { input: ParamsToPipeInput(Pipe) },
                ) !struct {
                    output: PipeOutput(Pipe),
                } {
                    return .{
                        .output = try Pipe.process(arena, props.input),
                    };
                }
            }, .{ .input = dirtyable_input });
            return result.output;
        }

        pub fn node(
            self: *@This(),
            comptime src: std.builtin.SourceLocation,
            Node: type,
            dirtyable_props: NodeInputs(Node),
        ) *NodeOutputs(Node) {
            const src_key = std.fmt.comptimePrint("{s}:{d}:{d}", .{ src.file, src.line, src.column });

            // Find existing state for this node.
            const state = if (self.node_states.getPtr(src_key)) |arena| arena else blk: {
                const node_self = self.allocator.create(Node) catch unreachable;
                node_self.* = if (@hasDecl(Node, "init")) Node.init(self.allocator) catch unreachable else .{};
                const new_state: NodeState = .{
                    .arena = .init(self.allocator),
                    .self = node_self,
                    .queried = .init(self.allocator),
                    .data = null,
                    .previous_data = null,
                };

                self.node_states.put(src_key, new_state) catch unreachable;
                break :blk self.node_states.getPtr(src_key).?;
            };

            // Fill in the input properties, taking note of if any of them are dirty, then the node is dirty, and we need to re-run the function.
            const Props = ParamsToNodeProps(Node);
            var props: Props = undefined;
            var is_input_dirty = false;
            switch (@typeInfo(Props)) {
                else => @compileError("Unhandled props type!"),
                .pointer => |p| switch (p.size) {
                    else => @compileError("Unhandled props type!"),
                    .slice => {
                        var props_list: std.ArrayList(p.child) = .init(self.frame_arena.allocator());
                        for (dirtyable_props) |dirtyable_prop| {
                            props_list.append(dirtyable_prop.raw) catch unreachable;
                            if (dirtyable_prop.is_dirty)
                                is_input_dirty = true;
                        }
                        props = props_list.items;
                    },
                },
                .@"struct" => |s| {
                    inline for (s.fields) |prop| {
                        var dirtyable_prop = @field(dirtyable_props, prop.name);
                        const default = dirtyable_prop.raw;
                        const input_field = switch (@typeInfo(prop.type)) {
                            .@"struct" => blk: {
                                if (utils_node.queryable.getSourceOrNull(prop.type)) |t| {
                                    const result = state.queried.getOrPut(prop.name) catch unreachable;
                                    if (!result.found_existing)
                                        result.value_ptr.* = false;
                                    break :blk utils_node.queryable.Value(t).initQueryable(
                                        dirtyable_prop.raw,
                                        dirtyable_prop.previous_raw,
                                        &dirtyable_prop.is_dirty,
                                        result.value_ptr,
                                    );
                                } else {
                                    break :blk default;
                                }
                            },
                            .pointer => |pointer| if (pointer.is_const) default else @compileError("Non-const pointer fields not allowed! " ++ prop.name),
                            else => default,
                        };
                        if (dirtyable_prop.is_dirty) {
                            is_input_dirty = true;
                        }
                        @field(props, prop.name) = input_field;
                    }
                },
            }

            if (!is_input_dirty and state.data != null) {
                // Just use the existing data from the last time the function had to run.
                const last_output: *NodeOutputs(Node) = @ptrCast(@alignCast(state.data.?));
                inline for (@typeInfo(@TypeOf(last_output.*)).@"struct".fields) |field| {
                    const last = &@field(last_output, field.name);
                    last.is_dirty = false;
                    last.previous_raw = last.raw;
                }
                return last_output;
            } else {
                // The node is dirty, or there's no data, so let's run the function!
                state.previous_data = state.data;
                state.arena.swap();

                const node_self: *Node = @ptrCast(@alignCast(state.self));
                const raw_outputs = Node.update(node_self, state.arena.allocator(), props);
                const outputs = switch (@typeInfo(@TypeOf(raw_outputs))) {
                    else => raw_outputs,
                    .error_union => raw_outputs catch @panic("Error thrown in a node call!"),
                };

                var node_output = state.arena.allocator().create(NodeOutputs(Node)) catch unreachable;

                const check_output_equality = if (@hasDecl(Node, "node_options")) Node.node_options.check_output_equality else false;
                inline for (@typeInfo(@TypeOf(outputs)).@"struct".fields) |field| {
                    const raw = @field(outputs, field.name);
                    const previous_raw = if (state.previous_data) |last_data| @field(
                        @as(*NodeOutputs(Node), @ptrCast(@alignCast(last_data))).*,
                        field.name,
                    ).raw else null;
                    @field(node_output, field.name) = .{
                        .raw = raw,
                        .previous_raw = previous_raw,
                        .is_dirty = if (check_output_equality)
                            if (previous_raw) |pr|
                                !std.meta.eql(raw, pr)
                            else
                                true
                        else
                            true,
                    };
                }

                state.data = @ptrCast(node_output);

                return node_output;
            }
        }

        const NodeState = struct {
            arena: utils.DoubleBufferedArena,
            self: *anyopaque,
            queried: std.StringHashMap(bool),
            data: ?*anyopaque,
            previous_data: ?*anyopaque,
        };

        pub fn build(graph: type) type {
            return struct {
                pub const State = graph.State;

                runtime: RuntimeSelf,
                inputs: StructFromUnion(Inputs),
                outputs: DirtyableFields(Outputs),
                state: State,
                frontend: *anyopaque,
                frontend_poll: *const FrontendPollFn,
                frontend_submit: *const FrontendSubmitFn,

                pub fn init(
                    allocator: std.mem.Allocator,
                    frontend: *anyopaque,
                    frontend_poll: *const FrontendPollFn,
                    frontend_submit: *const FrontendSubmitFn,
                    state: State,
                ) @This() {
                    var result = @This(){
                        .frontend = frontend,
                        .frontend_poll = frontend_poll,
                        .frontend_submit = frontend_submit,
                        .state = state,
                        .inputs = undefined,
                        .outputs = undefined,
                        .runtime = .{
                            .allocator = allocator,
                            .frame_arena = .init(allocator),
                            .node_states = std.StringHashMap(NodeState).init(allocator),
                        },
                    };
                    inline for (std.meta.fields(Inputs), 0..) |field, i| {
                        @setEvalBranchQuota(10000);
                        const input_tag: std.meta.FieldEnum(Inputs) = @enumFromInt(i);
                        const input_result = frontend_poll(frontend, &input_tag).*;
                        const value = switch (input_result) {
                            @field(std.meta.FieldEnum(Inputs), field.name) => |val| val,
                            else => unreachable,
                        };
                        @field(result.inputs, field.name) = value;
                    }
                    return result;
                }

                pub fn deinit(self: *@This()) void {
                    self.runtime.frame_arena.deinit();
                    var iter = self.runtime.node_states.valueIterator();
                    while (iter.next()) |node_state| {
                        node_state.queried.deinit();
                        node_state.arena.deinit();
                    }
                    self.runtime.node_states.deinit();
                }

                pub fn poll(
                    self: *@This(),
                    comptime field_tag: std.meta.FieldEnum(Inputs),
                ) Dirtyable(std.meta.fieldInfo(Inputs, field_tag).type) {
                    const previous = &@field(self.inputs, @tagName(field_tag));
                    const input_result = self.frontend_poll(self.frontend, &field_tag).*;
                    const current = switch (input_result) {
                        @field(std.meta.FieldEnum(Inputs), @tagName(field_tag)) => |value| value,
                        else => unreachable,
                    };
                    defer previous.* = current;
                    const is_dirty = !std.meta.eql(previous.*, current);
                    return .{
                        .is_dirty = is_dirty,
                        .previous_raw = previous.*,
                        .raw = current,
                    };
                }

                pub fn submit(
                    self: *@This(),
                    partial_outputs: utils.PartialFields(DirtyableFields(Outputs)),
                ) void {
                    inline for (std.meta.fields(Outputs)) |field| {
                        if (@field(partial_outputs, field.name)) |out| {
                            @field(self.outputs, field.name) = out;
                        }
                    }
                }

                pub fn update(self: *@This()) void {
                    self.runtime.frame_arena.swap();

                    var state: DirtyableFields(State) = undefined;
                    inline for (@typeInfo(@TypeOf(state)).@"struct".fields) |field| {
                        @field(state, field.name) = .{
                            .raw = @field(self.state, field.name),
                            .previous_raw = @field(self.state, field.name),
                            .is_dirty = false,
                        };
                    }

                    const output_state = graph.update(&self.runtime, self, state);

                    inline for (@typeInfo(@TypeOf(self.state)).@"struct".fields) |field| {
                        @field(self.state, field.name) = @field(output_state, field.name).raw;
                    }
                }

                pub fn processOutputs(self: *@This()) void {
                    var outputs = std.ArrayList(Outputs).init(self.runtime.frame_arena.allocator());
                    inline for (std.meta.fields(Outputs)) |field| {
                        const out = @field(self.outputs, field.name);
                        if (out.is_dirty) {
                            outputs.append(@unionInit(Outputs, field.name, out.raw)) catch unreachable;
                        }
                    }
                    self.frontend_submit(self.frontend, outputs.items.ptr, outputs.items.len);
                }
            };
        }
    };
}
