const std = @import("std");
const zoink = @import("zoink");

const AppState = struct {
    hits: std.atomic.Value(u64) = .init(0),
};

fn logger(ctx: *zoink.Context) !void {
    std.log.info("{t} {s}", .{ ctx.method, ctx.path });
    try ctx.next();
}

fn index(ctx: *zoink.Context) !void {
    try ctx.text(.ok, "welcome to zoink");
}

fn greet(ctx: *zoink.Context) !void {
    const name = ctx.param("name").?;
    var buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "hello, {s}!", .{name});
    try ctx.text(.ok, body);
}

const Echo = struct { message: []const u8 };

fn echo(ctx: *zoink.Context) !void {
    const body = try ctx.readJson(Echo);
    try ctx.sendJson(.ok, body);
}

fn hits(ctx: *zoink.Context) !void {
    const app = ctx.state(AppState);
    const n = app.hits.fetchAdd(1, .monotonic) + 1;
    try ctx.sendJson(.ok, .{ .hits = n });
}

fn assets(ctx: *zoink.Context) !void {
    try zoink.static.serve(ctx, "examples/public", ctx.param("path").?);
}

fn login(ctx: *zoink.Context) !void {
    try ctx.setCookie("session", "abc123", .{});
    try ctx.setCookie("theme", "dark", .{ .same_site = .strict, .max_age_seconds = 3600 });
    try ctx.text(.ok, "cookies set");
}

fn whoami(ctx: *zoink.Context) !void {
    const session = ctx.cookie("session") orelse "not logged in";
    try ctx.text(.ok, session);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var router: zoink.Router = .init(allocator);
    defer router.deinit();

    try router.use(logger);
    try router.get("/", index);
    try router.get("/greet/:name", greet);
    try router.post("/echo", echo);
    try router.get("/hits", hits);
    try router.get("/assets/*path", assets);
    try router.get("/login", login);
    try router.get("/whoami", whoami);

    var app_state: AppState = .{};

    var server: zoink.Server = .init(allocator, io, &router, .{
        .app_state = &app_state,
    });
    defer server.deinit();

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(8080) };
    try server.listen(address);

    std.log.info("listening on http://127.0.0.1:8080", .{});
    try server.run();
}
