const builtin = @import("builtin");
const std = @import("std");

const root = @import("root");
const alloc = root.alloc;
const config = root.config;
const logger = root.logger;
const util = root.util;

const os_char = root.util.os_char;

var mono_debug_init_called = false;
var mono_is_net35 = false;

const coreclr = root.runtimes.coreclr;
const il2cpp = root.runtimes.il2cpp;
const mono = root.runtimes.mono;

fn setenv(comptime key: [:0]const u8, value: [:0]const os_char) void {
    switch (builtin.os.tag) {
        .windows => {
            @import("windows/util.zig").SetEnvironmentVariable(key, value);
        },
        else => {
            @import("nix/util.zig").setenv(key, value, true);
        },
    }
}

fn mono_doorstop_bootstrap(mono_domain: *mono.Domain) void {
    if (std.process.hasEnvVarConstant("DOORSTOP_INITIALIZED")) {
        logger.debug("DOORSTOP_INITIALIZED is set! Skipping!", .{});
        return;
    }
    setenv("DOORSTOP_INITIALIZED", root.util.osStrLiteral("TRUE"));

    mono.addrs.thread_set_main.?(mono.addrs.thread_current.?());

    const app_path = root.util.paths.programPath();
    defer alloc.free(app_path);
    setenv("DOORSTOP_PROCESS_PATH", app_path);

    setenv("DOORSTOP_INVOKE_DLL_PATH", config.target_assembly.?);

    if (mono.addrs.domain_set_config) |domain_set_config| {
        const config_path = std.mem.concatWithSentinel(alloc, os_char, &.{
            app_path,
            util.osStrLiteral(".config"),
        }, 0) catch @panic("Out of memory");
        defer alloc.free(config_path);

        const config_path_n = util.narrow(config_path);
        defer config_path_n.deinit();

        const folder_path = root.util.paths.getFolderName(os_char, app_path);
        defer alloc.free(folder_path);
        const folder_path_n = util.narrow(folder_path);
        defer folder_path_n.deinit();

        logger.debug("Setting config paths: base dir: {s}; config path: {s}", .{ folder_path_n.str, config_path_n.str });

        domain_set_config(mono_domain, folder_path_n.str, config_path_n.str);
    }

    const assembly_dir = std.mem.span(mono.addrs.assembly_getrootdir.?());
    const norm_assembly_dir = util.widen(assembly_dir);
    defer norm_assembly_dir.deinit();

    mono.addrs.config_parse.?(null);

    logger.debug("Assembly dir: {s}", .{assembly_dir});
    setenv("DOORSTOP_MANAGED_FOLDER_DIR", norm_assembly_dir.str);

    logger.debug("Opening assembly: {}", .{util.fmtString(config.target_assembly.?)});

    const dll_path = util.narrow(config.target_assembly.?);
    defer dll_path.deinit();
    const image = blk: {
        var s = mono.ImageOpenFileStatus.ok;
        const image = mono.image_open_from_file_with_name(config.target_assembly.?, &s, 0, dll_path.str);
        if (s != .ok) {
            logger.err("Failed to open assembly: {s}. Got result: {}", .{ util.fmtString(config.target_assembly.?), s });
            return;
        }
        break :blk image.?;
    };

    logger.debug("Image opened; loading included assembly", .{});

    var s = mono.ImageOpenStatus.ok;
    _ = mono.addrs.assembly_load_from_full.?(image, dll_path.str, &s, 0);
    if (s != .ok) {
        logger.err("Failed to load assembly: {s}. Got result: {}", .{ util.fmtString(config.target_assembly.?), s });
        return;
    }

    logger.debug("Assembly loaded; looking for Doorstop.Entrypoint:Start", .{});
    const desc = mono.addrs.method_desc_new.?("Doorstop.Entrypoint:Start", 1);
    defer mono.addrs.method_desc_free.?(desc);
    const method = mono.addrs.method_desc_search_in_image.?(desc, image) orelse {
        @panic("Failed to find method Doorstop.Entrypoint:Start");
    };

    const signature = mono.addrs.method_signature.?(method);
    const params = mono.addrs.signature_get_param_count.?(signature);
    if (params != 0) {
        std.debug.panic("Method has {} parameters; expected 0", .{params});
    }

    logger.debug("Invoking method {}", .{util.fmtAddress(method)});
    var exc: ?*mono.Object = null;
    _ = mono.addrs.runtime_invoke.?(method, null, null, &exc);
    if (exc) |e| {
        logger.err("Error invoking code!", .{});
        if (mono.addrs.object_to_string) |object_to_string| {
            if (mono.addrs.string_to_utf8) |string_to_utf8| {
                const str = object_to_string(e, null);
                const exc_str = string_to_utf8(str);
                logger.err("Error message: {s}", .{exc_str});
            }
        }
    }
    logger.debug("Done", .{});
}

pub fn init_mono(root_domain_name: [*:0]const u8, runtime_version: [*:0]const u8) callconv(.c) ?*anyopaque {
    logger.debug("Starting mono domain \"{s}\"", .{root_domain_name});
    logger.debug("Runtime version: {s}", .{runtime_version});
    if (runtime_version[0] != 0 and runtime_version[1] != 0 and
        (runtime_version[1] == '2' or runtime_version[1] == '1'))
    {
        mono_is_net35 = true;
    }
    const root_dir = std.mem.span(@as([*:0]const u8, mono.addrs.assembly_getrootdir.?()));
    logger.debug("Current root: {s}", .{root_dir});

    logger.debug("Overriding mono DLL search path", .{});

    const mono_search_path_alloc = if (config.mono_dll_search_path_override) |paths| blk: {
        const mono_dll_search_path_override_n = util.narrow(paths);
        defer mono_dll_search_path_override_n.deinit();
        break :blk std.mem.concatWithSentinel(
            alloc,
            u8,
            &.{ mono_dll_search_path_override_n.str, &.{std.fs.path.delimiter}, root_dir },
            0,
        ) catch @panic("Out of memory");
    } else null;
    defer if (mono_search_path_alloc) |paths| alloc.free(paths);
    const mono_search_path = mono_search_path_alloc orelse root_dir;

    logger.debug("Mono search path: {s}", .{mono_search_path});
    mono.addrs.set_assemblies_path.?(mono_search_path);
    {
        const mono_search_path_w = util.widen(mono_search_path);
        defer mono_search_path_w.deinit();
        setenv("DOORSTOP_DLL_SEARCH_DIRS", mono_search_path_w.str);
    }

    hook_mono_jit_parse_options(0, &[_][*:0]u8{});

    var debugger_already_enabled = mono_debug_init_called;
    if (mono.addrs.debug_enabled) |debug_enabled| {
        debugger_already_enabled = debugger_already_enabled or debug_enabled() != 0;
    }

    if (config.mono_debug_enabled and !debugger_already_enabled) {
        logger.debug("Detected mono debugger is not initialized; initializing it", .{});
        mono.addrs.debug_init.?(mono.DebugFormat.mono);
    }
    const domain = mono.addrs.jit_init_version.?(root_domain_name, runtime_version);

    mono_doorstop_bootstrap(domain);

    return domain;
}

fn il2cpp_doorstop_bootstrap() void {
    const clr_corlib_dir = config.clr_corlib_dir orelse {
        @panic("CoreCLR paths not set");
    };
    const clr_runtime_coreclr_path = config.clr_runtime_coreclr_path orelse {
        @panic("CoreCLR paths not set");
    };

    logger.debug("CoreCLR runtime path: {}", .{util.fmtString(clr_runtime_coreclr_path)});
    logger.debug("CoreCLR corlib dir: {}", .{util.fmtString(clr_corlib_dir)});

    if (!util.paths.file_exists(clr_runtime_coreclr_path) or
        !util.paths.folder_exists(clr_corlib_dir))
    {
        logger.debug("CoreCLR startup dirs are not set up skipping invoking Doorstop", .{});
        return;
    }

    const coreclr_module = switch (builtin.os.tag) {
        .windows => std.os.windows.LoadLibraryW(clr_runtime_coreclr_path) catch @panic("Failed to load CoreCLR runtime"),
        else => std.c.dlopen(clr_runtime_coreclr_path, .{ .LAZY = true }) orelse @panic("Failed to load CoreCLR runtime"),
    };
    logger.debug("Loaded coreclr.dll: {}", .{util.fmtAddress(coreclr_module)});

    coreclr.load(coreclr_module);

    const app_path = util.paths.programPath();
    defer alloc.free(app_path);
    const app_path_n = util.narrow(app_path);
    defer app_path_n.deinit();

    const target_dir = util.paths.getFolderName(os_char, config.target_assembly.?);
    defer alloc.free(target_dir);
    const target_dir_n = util.narrow(target_dir);
    defer target_dir_n.deinit();
    const target_name = util.paths.getFileName(os_char, config.target_assembly.?, false);
    defer alloc.free(target_name);
    const target_name_n = util.narrow(target_name);
    defer target_name_n.deinit();

    const clr_corlib_dir_n = util.narrow(clr_corlib_dir);
    defer clr_corlib_dir_n.deinit();

    const app_paths_env = std.mem.concatWithSentinel(
        alloc,
        u8,
        &.{ clr_corlib_dir_n.str, &.{std.fs.path.delimiter}, target_dir_n.str },
        0,
    ) catch @panic("Out of memory");
    defer alloc.free(app_paths_env);

    logger.debug("App path: {}", .{util.fmtString(app_path)});
    logger.debug("Target dir: {}", .{util.fmtString(target_dir)});
    logger.debug("Target name: {}", .{util.fmtString(target_name)});
    logger.debug("APP_PATHS: {s}", .{app_paths_env});

    const props = "APP_PATHS";

    setenv("DOORSTOP_INITIALIZED", util.osStrLiteral("TRUE"));
    setenv("DOORSTOP_INVOKE_DLL_PATH", config.target_assembly.?);
    setenv("DOORSTOP_MANAGED_FOLDER_DIR", clr_corlib_dir);
    setenv("DOORSTOP_PROCESS_PATH", app_path);

    {
        const app_paths_env_w = util.widen(app_paths_env);
        defer app_paths_env_w.deinit();
        setenv("DOORSTOP_DLL_SEARCH_DIRS", app_paths_env_w.str);
    }

    var host: ?*anyopaque = null;
    var domain_id: u32 = 0;
    var result = coreclr.addrs.initialize.?(app_path_n.str, "Doorstop Domain", 1, &.{props}, &.{app_paths_env}, &host, &domain_id);
    if (result != 0) {
        std.debug.panic("Failed to initialize CoreCLR: 0x{x:0>8}", .{result});
    }

    var startup: ?*const fn () callconv(.c) void = null;
    result = coreclr.addrs.create_delegate.?(host.?, domain_id, target_name_n.str, "Doorstop.Entrypoint", "Start", @ptrCast(&startup));
    if (result != 0) {
        std.debug.panic("Failed to get entrypoint delegate: 0x{x:0>8}", .{result});
    }

    logger.debug("Invoking Doorstop.Entrypoint.Start()", .{});
    startup.?();
}

pub fn init_il2cpp(domain_name: [*:0]const u8) callconv(.c) i32 {
    logger.debug("Starting IL2CPP domain \"{s}\"", .{domain_name});
    const orig_result = il2cpp.addrs.init.?(domain_name);
    il2cpp_doorstop_bootstrap();
    return orig_result;
}

pub fn hook_mono_jit_parse_options(argc: c_int, argv: [*][*:0]u8) callconv(.c) void {
    const debug_options_buf = if (@import("Config.zig").getEnvStrRef("DNSPY_UNITY_DBG2")) |s| util.narrow(s) else null;
    defer if (debug_options_buf) |buf| buf.deinit();
    var debug_options = if (debug_options_buf) |buf| buf.str else null;
    defer if (debug_options) |s| if (debug_options_buf == null) alloc.free(s);
    if (debug_options != null) {
        config.mono_debug_enabled = true;
    }

    if (config.mono_debug_enabled) {
        logger.debug("Configuring mono debug server", .{});

        const size = argc + 1;
        const new_argv = alloc.alloc([*:0]const u8, @intCast(size)) catch @panic("Out of memory");
        defer alloc.free(new_argv);
        @memcpy(new_argv[0..@intCast(argc)], argv);

        if (debug_options == null) {
            const mono_debug_address_alloc = if (config.mono_debug_address) |s| util.narrow(s) else null;
            defer if (mono_debug_address_alloc) |s| s.deinit();
            const mono_debug_address: []const u8 = if (mono_debug_address_alloc) |s| s.str else "127.0.0.1:10000";

            const MONO_DEBUG_NO_SUSPEND = ",suspend=n";
            const MONO_DEBUG_NO_SUSPEND_NET35 = ",suspend=n,defer=y";
            debug_options = std.fmt.allocPrintZ(alloc, "--debugger-agent=transport=dt_socket,server=y,address={s}{s}", .{
                mono_debug_address,
                if (config.mono_debug_suspend) "" else if (mono_is_net35) MONO_DEBUG_NO_SUSPEND_NET35 else MONO_DEBUG_NO_SUSPEND,
            }) catch @panic("Out of memory");
        }

        logger.debug("Debug options: {s}", .{debug_options.?});

        new_argv[@intCast(argc)] = debug_options.?;
        mono.addrs.jit_parse_options.?(size, new_argv.ptr);
    } else {
        mono.addrs.jit_parse_options.?(argc, argv);
    }
}

pub fn hook_mono_image_open_from_data_with_name(
    data: [*]const u8,
    data_len: u32,
    need_copy: i32,
    status: *mono.ImageOpenStatus,
    refonly: i32,
    name: [*:0]const u8,
) callconv(.c) ?*mono.Image {
    if (config.mono_dll_search_path_override) |mono_dll_search_path_override| {
        const name_file = root.util.paths.getFileNameRef(u8, std.mem.span(name), true);

        const name_file_len = std.unicode.calcWtf16LeLen(name_file) catch @panic("Invalid WTF-8");
        const new_full_path = alloc.allocSentinel(os_char, name_file_len + 1 + mono_dll_search_path_override.len, 0) catch @panic("Out of memory");
        defer alloc.free(new_full_path);
        @memcpy(new_full_path[0..mono_dll_search_path_override.len], mono_dll_search_path_override);
        new_full_path[mono_dll_search_path_override.len] = '/';
        if (builtin.os.tag == .windows) {
            _ = std.unicode.wtf8ToWtf16Le(new_full_path[mono_dll_search_path_override.len + 1 ..], name_file) catch @panic("Invalid WTF-8");
        } else {
            @memcpy(new_full_path[mono_dll_search_path_override.len + 1 ..], name_file);
        }

        var attemptStatus: mono.ImageOpenFileStatus = @enumFromInt(@intFromEnum(status.*));
        const result = mono.image_open_from_file_with_name(new_full_path, &attemptStatus, refonly, std.mem.span(name));
        switch (attemptStatus) {
            .ok => return result.?,
            .file_not_found => {},
            else => {
                logger.err("Failed to load overridden Mono image: Error: {}", .{attemptStatus});

                switch (attemptStatus) {
                    .ok, .file_not_found => unreachable,
                    .missing_assemblyref, .image_invalid, .error_errno => {
                        status.* = @enumFromInt(@intFromEnum(attemptStatus));
                    },
                    .file_error => {
                        // not sure what is the best way to adapt this error
                        status.* = .image_invalid;
                    },
                }
                return null;
            },
        }
    }

    return mono.addrs.image_open_from_data_with_name.?(data, data_len, need_copy, status, refonly, name);
}

pub fn hook_mono_debug_init(format: root.runtimes.mono.DebugFormat) callconv(.c) void {
    mono_debug_init_called = true;
    _ = mono.addrs.debug_init.?(format);
}
