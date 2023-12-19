const std = @import("std");
const win = @cImport({
    @cInclude("windows.h");
    @cInclude("psapi.h");
    @cInclude("aclapi.h");
    @cInclude("Tlhelp32.h");
});
const log = std.log;

const config_file_name = "ecofy.conf";

var file_buff: [1 << 14]u8 = undefined; // 16K max
var name_buff: [512][]const u8 = undefined; // Because we dont use linear scan.
var hash_map_buff: [1 << 12]u8 = undefined;

pub fn main() !void {
    var fba = std.heap.FixedBufferAllocator.init(&file_buff);
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
            log.info("Watched name: \"{s}\"", .{name});
            if (name_count >= name_buff.len) return error.TooManyNames;
            name_buff[name_count] = name;
            name_count += 1;
        }
    }

    const names = name_buff[0..name_count];

    var hashmap_fba = std.heap.FixedBufferAllocator.init(&hash_map_buff);
    const hash_alloc = hashmap_fba.allocator();

    {
        const snapshot = win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS | win.TH32CS_SNAPTHREAD, 0);

        if (snapshot == win.INVALID_HANDLE_VALUE) {
            log.err("Failed to get process snapshot, error code: {}", .{win.GetLastError()});
            return error.WINAPI;
        }

        var process: win.PROCESSENTRY32 = undefined;
        process.dwSize = @sizeOf(@TypeOf(process));

        if (win.Process32First(snapshot, &process) == 0) {
            log.err("Failed to copy process information from snapshot, error code: {}", .{win.GetLastError()});
            return error.WINAPI;
        }

        var important_ids = std.AutoHashMap(win.DWORD, void).init(hash_alloc);
        defer hashmap_fba.reset();

        while (true) {
            const proc_name = std.mem.sliceTo(&process.szExeFile, 0);
            log.info("Opened Process: \"{s}\", Id: {}", .{ proc_name, process.th32ProcessID });
            //log.debug("{}", .{process});

            for (names) |watched_name| {
                if (std.mem.eql(u8, watched_name, proc_name)) {
                    std.log.info("Process Id: {} matched \"{s}\"", .{ process.th32ProcessID, watched_name });
                    try important_ids.put(process.th32ProcessID, {});
                }
            }

            if (win.Process32Next(snapshot, &process) == 0) {
                const err = win.GetLastError();
                if (err == win.ERROR_NO_MORE_FILES) break;
                log.err("Failed to get next process information, error code: {}", .{err});
            }
        }

        if (win.CloseHandle(snapshot) == 0) {
            log.err("Failed to close snapshot, error code: {}", .{win.GetLastError()});
            return error.WINAPI;
        }
    }

    // var buff16: [1 << 8]u16 = undefined;
    // var buff8: [1 << 8]u8 = undefined;

    // const name_len_u16 = win.GetProcessImageFileNameW(handle, &buff16, buff16.len);
    // if (name_len_u16 == 0) {
    //     log.err("Failed to get image name, error code: {}", .{win.GetLastError()});
    //     return error.WINAPI;
    // }

    // const name_len_u8 = try std.unicode.utf16leToUtf8(&buff8, buff16[0..name_len_u16]);
    // const proc_name = buff8[0..name_len_u8];

    // log.debug("Open process: {s}", .{proc_name});

    // var any_match = false;
    // for (names) |name| {
    //     if (std.mem.indexOf(u8, proc_name, name) != null) {
    //         log.info("Process matched to {s}", .{name});
    //         any_match = true;
    //         break;
    //     }
    // }

    // if (any_match) {
    //     var process_info: win.PROCESS_POWER_THROTTLING_STATE = .{
    //         .Version = win.PROCESS_POWER_THROTTLING_CURRENT_VERSION,
    //         .ControlMask = win.PROCESS_POWER_THROTTLING_EXECUTION_SPEED,
    //         .StateMask = win.PROCESS_POWER_THROTTLING_EXECUTION_SPEED,
    //     };

    //     if (win.SetProcessInformation(
    //         handle,
    //         win.ProcessPowerThrottling,
    //         &process_info,
    //         @sizeOf(@TypeOf(process_info)),
    //     ) == 0) {
    //         log.err("Failed to set process information, error code: {}", .{win.GetLastError()});
    //         return error.WINAPI;
    //     }
    //     log.info("Set \"{s}\" to EcoQoS", .{proc_name});

}
