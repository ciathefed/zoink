//! Static file serving, callable from within a regular handler:
//!
//!     fn assets(ctx: *Context) !void {
//!         try zoink.static.serve(ctx, "public", ctx.param("path").?);
//!     }
//!     try router.get("/assets/*path", assets);
const std = @import("std");
const Context = @import("Context.zig");

/// Serves `rel_path` (as captured from e.g. a `*path` wildcard) from
/// `root`, rejecting any path that attempts to escape `root` via `..`.
/// An empty `rel_path` serves `index.html`.
pub fn serve(ctx: *Context, root: []const u8, rel_path_in: []const u8) !void {
    const rel_path = if (rel_path_in.len == 0) "index.html" else rel_path_in;

    if (!isSafe(rel_path)) {
        try ctx.text(.forbidden, "403 forbidden");
        return;
    }

    var dir = std.Io.Dir.cwd().openDir(ctx.io, root, .{}) catch {
        try ctx.text(.not_found, "404 not found");
        return;
    };
    defer dir.close(ctx.io);

    var file = dir.openFile(ctx.io, rel_path, .{}) catch {
        try ctx.text(.not_found, "404 not found");
        return;
    };
    defer file.close(ctx.io);

    const size = try file.length(ctx.io);
    const read_buf = try ctx.allocator.alloc(u8, 8192);
    var file_reader = std.Io.File.Reader.initSize(file, ctx.io, read_buf, size);
    // limit must exceed the known size so EndOfStream is hit before the cap.
    const contents = try file_reader.interface.allocRemaining(ctx.allocator, .limited64(size + 1));

    try ctx.respond(.ok, contentType(rel_path), contents, .{});
}

fn isSafe(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

const mime_types = .{
    .{ ".html", "text/html; charset=utf-8" },
    .{ ".htm", "text/html; charset=utf-8" },
    .{ ".css", "text/css; charset=utf-8" },
    .{ ".js", "text/javascript; charset=utf-8" },
    .{ ".json", "application/json" },
    .{ ".png", "image/png" },
    .{ ".jpg", "image/jpeg" },
    .{ ".jpeg", "image/jpeg" },
    .{ ".gif", "image/gif" },
    .{ ".svg", "image/svg+xml" },
    .{ ".ico", "image/x-icon" },
    .{ ".txt", "text/plain; charset=utf-8" },
    .{ ".wasm", "application/wasm" },
    .{ ".woff", "font/woff" },
    .{ ".woff2", "font/woff2" },
    .{ ".pdf", "application/pdf" },
};

fn contentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    inline for (mime_types) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}
