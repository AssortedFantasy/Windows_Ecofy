const std = @import("std");
const win = @cImport({
    @cInclude("windows.h");
    @cInclude("psapi.h");
});

var procs: [1 << 10]win.DWORD = undefined;

pub fn main() !void {
    var bytes_returned: win.DWORD = undefined;
    const result = win.EnumProcesses(
        &procs,
        @sizeOf(@TypeOf(procs)),
        &bytes_returned,
    );

    if (result == 0) {
        std.log.debug("could not get processes, error code: {}\n", .{win.GetLastError()});
        return error.WINAPI;
    }

    const num_procs = @divExact(bytes_returned, @sizeOf(win.DWORD));
    const valid_procs = procs[0..num_procs];

    for (valid_procs) |proc_id| {
        const handle = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, win.FALSE, proc_id);

        if (handle == null) {
            std.log.debug("Failed to open processes id: {}, error code: {}\n", .{ proc_id, win.GetLastError() });
            continue;
        } else {
            std.log.debug("opened id: {}\n", .{proc_id});
        }

        var buff16: [1 << 8]u16 = undefined;
        var buff8: [1 << 8]u8 = undefined;

        const name_len_u16 = win.GetProcessImageFileNameW(handle, &buff16, buff16.len);
        if (name_len_u16 == 0) {
            std.log.debug("Failed to get image name, error code: {}\n", .{win.GetLastError()});
            return error.WINAPI;
        }

        const name_len_u8 = try std.unicode.utf16leToUtf8(&buff8, buff16[0..name_len_u16]);
        const name = buff8[0..name_len_u8];

        std.log.debug("Open process: {s}\n", .{name});

        const close_result = win.CloseHandle(handle);
        if (close_result == 0) {
            std.log.debug("Failed to close handle, error code: {}\n", .{win.GetLastError()});
            return error.WINAPI;
        }
    }

    std.log.debug("{}\n", .{num_procs});
}
