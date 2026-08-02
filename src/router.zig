const std = @import("std");
const http = std.http;
const Context = @import("Context.zig");

/// A request handler, or a middleware step. Middleware calls `ctx.next()`
/// to continue the chain; a terminal handler simply returns.
pub const Handler = *const fn (*Context) anyerror!void;

/// Path parameters captured while matching a route, e.g. `:id` in `/users/:id`.
pub const Params = struct {
    pub const max = 8;

    names: [max][]const u8 = undefined,
    values: [max][]const u8 = undefined,
    len: u8 = 0,

    pub fn get(self: *const Params, name: []const u8) ?[]const u8 {
        for (self.names[0..self.len], self.values[0..self.len]) |n, v| {
            if (std.mem.eql(u8, n, name)) return v;
        }
        return null;
    }

    fn push(self: *Params, name: []const u8, value: []const u8) void {
        if (self.len >= max) return;
        self.names[self.len] = name;
        self.values[self.len] = value;
        self.len += 1;
    }
};

/// Methods collected while matching, when a request's path matches a route
/// but its method doesn't. One slot per `http.Method` variant is enough.
pub const AllowedMethods = struct {
    pub const max = @typeInfo(http.Method).@"enum".fields.len;

    methods: [max]http.Method = undefined,
    len: u8 = 0,

    pub fn slice(self: *const AllowedMethods) []const http.Method {
        return self.methods[0..self.len];
    }

    fn push(self: *AllowedMethods, method: http.Method) void {
        for (self.methods[0..self.len]) |m| {
            if (m == method) return;
        }
        if (self.len >= max) return;
        self.methods[self.len] = method;
        self.len += 1;
    }
};

const SegmentKind = enum { literal, param, wildcard };

const Segment = struct {
    kind: SegmentKind,
    text: []const u8,
};

const Route = struct {
    method: ?http.Method,
    pattern: []const u8,
    /// Whether `pattern` was allocated by the router (via `Group`) and so
    /// must be freed in `deinit`, as opposed to caller-owned (e.g. a string
    /// literal passed directly to `Router.get` and friends).
    owns_pattern: bool,
    segments: []const Segment,
    handler: Handler,
};

pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayList(Route) = .empty,
    middlewares: std.ArrayList(Handler) = .empty,

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Router) void {
        for (self.routes.items) |route| {
            self.allocator.free(route.segments);
            if (route.owns_pattern) self.allocator.free(route.pattern);
        }
        self.routes.deinit(self.allocator);
        self.middlewares.deinit(self.allocator);
    }

    /// Registers a middleware that runs for every request, in registration
    /// order, before the matched route's handler. Call `ctx.next()` from
    /// within it to continue the chain.
    pub fn use(self: *Router, handler: Handler) !void {
        try self.middlewares.append(self.allocator, handler);
    }

    pub fn get(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.add(.GET, pattern, handler);
    }

    pub fn post(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.add(.POST, pattern, handler);
    }

    pub fn put(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.add(.PUT, pattern, handler);
    }

    pub fn patch(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.add(.PATCH, pattern, handler);
    }

    pub fn delete(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.add(.DELETE, pattern, handler);
    }

    /// Matches any HTTP method.
    pub fn any(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.add(null, pattern, handler);
    }

    pub fn add(self: *Router, method: ?http.Method, pattern: []const u8, handler: Handler) !void {
        try self.addImpl(method, pattern, false, handler);
    }

    /// Registers a group of routes sharing a common path prefix, e.g.:
    ///
    ///     const api = router.group("/api");
    ///     try api.get("/users", listUsers);   // matches "/api/users"
    ///     try api.post("/users", createUser); // matches "/api/users"
    ///
    /// `prefix` must start with `/` and must not end with one.
    pub fn group(self: *Router, prefix: []const u8) Group {
        std.debug.assert(prefix.len > 1 and prefix[0] == '/' and prefix[prefix.len - 1] != '/');
        return .{ .router = self, .prefix = prefix };
    }

    fn addImpl(self: *Router, method: ?http.Method, pattern: []const u8, owns_pattern: bool, handler: Handler) !void {
        std.debug.assert(pattern.len > 0 and pattern[0] == '/');
        errdefer if (owns_pattern) self.allocator.free(pattern);

        var segments: std.ArrayList(Segment) = .empty;
        errdefer segments.deinit(self.allocator);

        var it = std.mem.splitScalar(u8, pattern, '/');
        _ = it.next(); // leading empty piece before the first '/'
        while (it.next()) |piece| {
            if (piece.len == 0) continue;
            const seg: Segment = switch (piece[0]) {
                ':' => .{ .kind = .param, .text = piece[1..] },
                '*' => .{ .kind = .wildcard, .text = piece[1..] },
                else => .{ .kind = .literal, .text = piece },
            };
            try segments.append(self.allocator, seg);
        }

        try self.routes.append(self.allocator, .{
            .method = method,
            .pattern = pattern,
            .owns_pattern = owns_pattern,
            .segments = try segments.toOwnedSlice(self.allocator),
            .handler = handler,
        });
    }

    pub const Outcome = union(enum) {
        found: Handler,
        /// The path matched at least one route, but none for this method.
        /// `allowed` (filled by `match`) lists the methods that would have
        /// matched.
        method_not_allowed,
        not_found,
    };

    /// Finds the route matching `method` and `path`, filling `params` with
    /// any captured path segments. If the path matches a route but the
    /// method doesn't, returns `.method_not_allowed` and fills `allowed`
    /// with the methods that do match the path.
    pub fn match(self: *const Router, method: http.Method, path: []const u8, params: *Params, allowed: *AllowedMethods) Outcome {
        allowed.len = 0;
        for (self.routes.items) |route| {
            params.len = 0;
            if (!matchSegments(route.segments, path, params)) continue;

            if (route.method == null or route.method.? == method) return .{ .found = route.handler };
            allowed.push(route.method.?);
        }
        return if (allowed.len == 0) .not_found else .method_not_allowed;
    }
};

/// A path prefix under which routes can be registered without repeating it
/// each time. Create with `Router.group`; each registered route allocates
/// its own owned copy of `prefix ++ pattern`, freed by `Router.deinit`.
pub const Group = struct {
    router: *Router,
    prefix: []const u8,

    pub fn get(self: Group, pattern: []const u8, handler: Handler) !void {
        try self.add(.GET, pattern, handler);
    }

    pub fn post(self: Group, pattern: []const u8, handler: Handler) !void {
        try self.add(.POST, pattern, handler);
    }

    pub fn put(self: Group, pattern: []const u8, handler: Handler) !void {
        try self.add(.PUT, pattern, handler);
    }

    pub fn patch(self: Group, pattern: []const u8, handler: Handler) !void {
        try self.add(.PATCH, pattern, handler);
    }

    pub fn delete(self: Group, pattern: []const u8, handler: Handler) !void {
        try self.add(.DELETE, pattern, handler);
    }

    /// Matches any HTTP method.
    pub fn any(self: Group, pattern: []const u8, handler: Handler) !void {
        try self.add(null, pattern, handler);
    }

    fn add(self: Group, method: ?http.Method, pattern: []const u8, handler: Handler) !void {
        std.debug.assert(pattern.len > 0 and pattern[0] == '/');
        const joined = try std.mem.concat(self.router.allocator, u8, &.{ self.prefix, pattern });
        try self.router.addImpl(method, joined, true, handler);
    }
};

fn matchSegments(segments: []const Segment, path: []const u8, params: *Params) bool {
    var pos: usize = if (path.len > 0 and path[0] == '/') 1 else 0;

    for (segments, 0..) |seg, idx| {
        if (seg.kind == .wildcard) {
            params.push(seg.text, path[pos..]);
            return idx == segments.len - 1;
        }

        if (pos > path.len) return false;
        const next_slash = std.mem.indexOfScalarPos(u8, path, pos, '/');
        const end = next_slash orelse path.len;
        const piece = path[pos..end];
        if (piece.len == 0) return false;

        switch (seg.kind) {
            .literal => if (!std.mem.eql(u8, seg.text, piece)) return false,
            .param => params.push(seg.text, piece),
            .wildcard => unreachable,
        }

        pos = if (next_slash) |s| s + 1 else path.len + 1;
    }

    return pos == path.len or pos == path.len + 1;
}

test "matches literal and param segments" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    const S = struct {
        fn handler(ctx: *Context) !void {
            _ = ctx;
        }
    };

    try router.get("/users/:id", S.handler);
    try router.post("/users/:id", S.handler);
    try router.get("/users/:id/posts/:post_id", S.handler);
    try router.get("/", S.handler);
    try router.get("/assets/*path", S.handler);

    var params: Params = .{};
    var allowed: AllowedMethods = .{};

    try std.testing.expect(router.match(.GET, "/users/42", &params, &allowed) == .found);
    try std.testing.expectEqualStrings("42", params.get("id").?);

    params = .{};
    try std.testing.expect(router.match(.GET, "/users/42/posts/7", &params, &allowed) == .found);
    try std.testing.expectEqualStrings("42", params.get("id").?);
    try std.testing.expectEqualStrings("7", params.get("post_id").?);

    params = .{};
    try std.testing.expect(router.match(.GET, "/", &params, &allowed) == .found);

    params = .{};
    try std.testing.expect(router.match(.GET, "/assets/css/app.css", &params, &allowed) == .found);
    try std.testing.expectEqualStrings("css/app.css", params.get("path").?);

    params = .{};
    try std.testing.expect(router.match(.GET, "/nope", &params, &allowed) == .not_found);

    params = .{};
    try std.testing.expect(router.match(.DELETE, "/users/42", &params, &allowed) == .method_not_allowed);
    try std.testing.expectEqual(2, allowed.len);
    var saw_get = false;
    var saw_post = false;
    for (allowed.slice()) |m| {
        if (m == .GET) saw_get = true;
        if (m == .POST) saw_post = true;
    }
    try std.testing.expect(saw_get and saw_post);
}

test "route groups prefix their patterns" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    const S = struct {
        fn handler(ctx: *Context) !void {
            _ = ctx;
        }
    };

    const api = router.group("/api");
    try api.get("/users/:id", S.handler);
    try api.post("/users", S.handler);

    var params: Params = .{};
    var allowed: AllowedMethods = .{};

    try std.testing.expect(router.match(.GET, "/api/users/42", &params, &allowed) == .found);
    try std.testing.expectEqualStrings("42", params.get("id").?);

    try std.testing.expect(router.match(.POST, "/api/users", &params, &allowed) == .found);
    try std.testing.expect(router.match(.GET, "/users/42", &params, &allowed) == .not_found);
}
