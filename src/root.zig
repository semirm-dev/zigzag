//! The zbridge library module: parse -> validate -> generate, with no CLI or
//! build-system concerns. Both front ends (the `zbridge` CLI and the
//! `build.zig` integration) go through this.

pub const ir = @import("core/ir.zig");
pub const diagnostics = @import("core/diagnostics.zig");
pub const targets = @import("core/targets.zig");
pub const abi_hash = @import("core/abi_hash.zig");
pub const parse = @import("core/parse.zig");
pub const validate = @import("core/validate.zig");
pub const generate = @import("core/generate.zig");

pub const gen = struct {
    pub const context = @import("gen/context.zig");
    pub const writer = @import("gen/writer.zig");
    pub const names = @import("gen/names.zig");
    pub const go = @import("gen/go.zig");
    pub const python = @import("gen/python.zig");
    pub const c_header = @import("gen/c_header.zig");
};

pub const version = @import("version.zig");

// Re-exported for convenience at the call sites that matter most.
pub const Api = ir.Api;
pub const Options = generate.Options;
pub const run = generate.run;
pub const writeFiles = generate.writeFiles;
pub const writeFilesInto = generate.writeFilesInto;

test {
    @import("std").testing.refAllDecls(@This());
}
