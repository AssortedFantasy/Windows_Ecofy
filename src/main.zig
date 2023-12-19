const std = @import("std");
const win = @cImport({
    @cInclude("windows.h");
    @cInclude("psapi.h");
    @cInclude("aclapi.h");
});

const config_file_name = "ecofy.conf";
var procs: [1 << 10]win.DWORD = undefined;

var mem_buff: [1 << 14]u8 = undefined; // 16K max
var name_buff: [512][]const u8 = undefined; // Because we dont use linear scan.

pub fn main() !void {
    var fba = std.heap.FixedBufferAllocator.init(&mem_buff);
    const allocator = fba.allocator();

    const config = try std.fs.cwd().openFile(config_file_name, .{});
    const buff = try config.readToEndAlloc(allocator, std.math.maxInt(u32));
    config.close();
    // Don't need to free.
    // Kept till program exits.

    var it = std.mem.splitAny(u8, buff, "\r\n");
    var name_count: usize = 0;
    while (it.next()) |name| {
        if (name.len > 0) {
            std.log.info("Watched name: \"{s}\"", .{name});
            if (name_count >= name_buff.len) return error.TooManyNames;
            name_buff[name_count] = name;
            name_count += 1;
        }
    }

    const names = name_buff[0..name_count];

    var bytes_returned: win.DWORD = undefined;
    const result = win.EnumProcesses(
        &procs,
        @sizeOf(@TypeOf(procs)),
        &bytes_returned,
    );

    if (result == 0) {
        std.log.err("Could not get processes, error code: {}", .{win.GetLastError()});
        return error.WINAPI;
    }

    const num_procs = @divExact(bytes_returned, @sizeOf(win.DWORD));
    std.log.info("Got {} processes", .{num_procs});
    const valid_procs = procs[0..num_procs];

    for (valid_procs) |proc_id| {
        const handle = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION | win.PROCESS_SET_INFORMATION, win.FALSE, proc_id);

        if (handle == null) {
            std.log.warn("Failed to open processes id: {}, error code: {}", .{ proc_id, win.GetLastError() });
            continue;
        } else {
            std.log.info("Opened id: {}", .{proc_id});
        }

        var buff16: [1 << 8]u16 = undefined;
        var buff8: [1 << 8]u8 = undefined;

        const name_len_u16 = win.GetProcessImageFileNameW(handle, &buff16, buff16.len);
        if (name_len_u16 == 0) {
            std.log.err("Failed to get image name, error code: {}", .{win.GetLastError()});
            return error.WINAPI;
        }

        const name_len_u8 = try std.unicode.utf16leToUtf8(&buff8, buff16[0..name_len_u16]);
        const proc_name = buff8[0..name_len_u8];

        std.log.debug("Open process: {s}", .{proc_name});

        var any_match = false;
        for (names) |name| {
            if (std.mem.indexOf(u8, proc_name, name) != null) {
                std.log.info("Process matched to {s}", .{name});
                any_match = true;
                break;
            }
        }

        if (any_match) {}

        const close_result = win.CloseHandle(handle);
        if (close_result == 0) {
            std.log.err("Failed to close handle, error code: {}", .{win.GetLastError()});
            return error.WINAPI;
        }
    }
}
