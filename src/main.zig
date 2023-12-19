const std = @import("std");
const win = @cImport({
    @cInclude("windows.h");
    @cInclude("psapi.h");
    @cInclude("processthreadsapi.h");
    @cInclude("aclapi.h");
    @cInclude("Tlhelp32.h");
});
const log = std.log;

const config_file_name = "ecofy.conf";

var file_buff: [1 << 14]u8 = undefined; // 16K max
var name_buff: [512][]const u8 = undefined; // Because we dont use linear scan.
var hash_map_buff: [1 << 12]u8 = undefined;

const EcoErrors = error{
    WINAPI,
    ToManyWatches,
};

pub fn main() !void {
    var fba = std.heap.FixedBufferAllocator.init(&file_buff);
    const allocator = fba.allocator();

    const config = try std.fs.cwd().openFile(config_file_name, .{});
    const buff = try config.readToEndAlloc(allocator, std.math.maxInt(u32));
    config.close();

    var it = std.mem.splitAny(u8, buff, "\r\n");
    var name_count: usize = 0;
    while (it.next()) |name| {
        if (name.len > 0) {
            log.info("Watched name: \"{s}\"", .{name});
            if (name_count >= name_buff.len) return EcoErrors.ToManyWatches;
            name_buff[name_count] = name;
            name_count += 1;
        }
    }

    const names = name_buff[0..name_count];

    var hashmap_fba = std.heap.FixedBufferAllocator.init(&hash_map_buff);
    const hash_alloc = hashmap_fba.allocator();

    while (true) {
        // const snapshot = win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS | win.TH32CS_SNAPTHREAD, 0);
        const snapshot = win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0);

        if (snapshot == win.INVALID_HANDLE_VALUE) {
            log.err("Failed to get process snapshot, error code: {}", .{win.GetLastError()});
            return EcoErrors.WINAPI;
        }

        var process: win.PROCESSENTRY32 = undefined;
        process.dwSize = @sizeOf(@TypeOf(process));

        if (win.Process32First(snapshot, &process) == 0) {
            log.err("Failed to copy process information from snapshot, error code: {}", .{win.GetLastError()});
            return EcoErrors.WINAPI;
        }

        // Set of processes which we want to have EcoQoSed
        var important_ids = std.AutoHashMap(win.DWORD, void).init(hash_alloc);
        defer hashmap_fba.reset();

        while (true) {
            const proc_name = std.mem.sliceTo(&process.szExeFile, 0);
            log.debug("Opened Process: \"{s}\", Id: {}", .{ proc_name, process.th32ProcessID });
            //log.debug("{}", .{process});

            for (names) |watched_name| {
                if (std.mem.eql(u8, watched_name, proc_name)) {
                    std.log.info("Process Id: {} matched \"{s}\"", .{ process.th32ProcessID, watched_name });
                    try important_ids.put(process.th32ProcessID, {});

                    // Set to EcoQoS.
                    const proc_handle = win.OpenProcess(win.PROCESS_SET_INFORMATION, win.FALSE, process.th32ProcessID);
                    if (proc_handle == null) {
                        std.log.warn("Failed to open process: {} \"{s}\", error code: {}", .{ process.th32ProcessID, proc_name, win.GetLastError() });
                        continue;
                    }

                    var process_info: win.PROCESS_POWER_THROTTLING_STATE = .{
                        .Version = win.PROCESS_POWER_THROTTLING_CURRENT_VERSION,
                        .ControlMask = win.PROCESS_POWER_THROTTLING_EXECUTION_SPEED,
                        .StateMask = win.PROCESS_POWER_THROTTLING_EXECUTION_SPEED,
                    };

                    if (win.SetProcessInformation(
                        proc_handle,
                        win.ProcessPowerThrottling,
                        &process_info,
                        @sizeOf(@TypeOf(process_info)),
                    ) == 0) {
                        log.err("Failed to set process information, error code: {}", .{win.GetLastError()});
                        return EcoErrors.WINAPI;
                    }

                    if (win.SetPriorityClass(proc_handle, win.IDLE_PRIORITY_CLASS) == 0) {
                        log.err("Failed to set idle priority class, error code: {}", .{win.GetLastError()});
                        return EcoErrors.WINAPI;
                    }

                    log.info("Set \"{s}\" to EcoQoS", .{proc_name});

                    if (win.CloseHandle(proc_handle) == 0) {
                        std.log.err("Failed to close process handle, error code: {}", .{win.GetLastError()});
                        return EcoErrors.WINAPI;
                    }
                }
            }

            if (win.Process32Next(snapshot, &process) == 0) {
                const err = win.GetLastError();
                if (err == win.ERROR_NO_MORE_FILES) break;
                log.err("Failed to get next process information, error code: {}", .{err});
                return EcoErrors.WINAPI;
            }
        }

        // We dont need thread stuff.
        if (false) {
            var thread: win.THREADENTRY32 = undefined;
            thread.dwSize = @sizeOf(@TypeOf(thread));

            if (win.Thread32First(snapshot, &thread) == 0) {
                log.err("Failed to copy thread information from snapshot, error code: {}", .{win.GetLastError()});
                return EcoErrors.WINAPI;
            }

            while (true) {
                //log.debug("Thread: {} {}", .{ thread.th32OwnerProcessID, thread.th32ThreadID });
                if (important_ids.contains(thread.th32OwnerProcessID)) {
                    log.info("Thread {} owned by watched {}", .{ thread.th32ThreadID, thread.th32OwnerProcessID });

                    // Set to EcoQoS
                    const thread_handle = win.OpenThread(win.THREAD_SET_INFORMATION, win.FALSE, thread.th32ThreadID);
                    if (thread_handle == null) {
                        std.log.warn("Failed to open thread: {}, error code: {}", .{ thread.th32ThreadID, win.GetLastError() });
                        continue;
                    }

                    var thread_info: win.THREAD_POWER_THROTTLING_STATE = .{
                        .Version = win.THREAD_POWER_THROTTLING_CURRENT_VERSION,
                        .ControlMask = win.THREAD_POWER_THROTTLING_EXECUTION_SPEED,
                        .StateMask = win.THREAD_POWER_THROTTLING_EXECUTION_SPEED,
                    };

                    if (win.SetThreadInformation(
                        thread_handle,
                        win.ThreadPowerThrottling,
                        &thread_info,
                        @sizeOf(@TypeOf(thread_info)),
                    ) == 0) {
                        log.err("Failed to set thread information, error code: {}", .{win.GetLastError()});
                        return EcoErrors.WINAPI;
                    }

                    log.info("Set \"{}\" to EcoQoS", .{thread.th32ThreadID});

                    if (win.CloseHandle(thread_handle) == 0) {
                        std.log.err("Failed to close thread handle, error code: {}", .{win.GetLastError()});
                        return EcoErrors.WINAPI;
                    }
                }

                if (win.Thread32Next(snapshot, &thread) == 0) {
                    const err = win.GetLastError();
                    if (err == win.ERROR_NO_MORE_FILES) break;
                    log.err("Failed to get next thread information from snapshot, error code: {}", .{err});
                    return EcoErrors.WINAPI;
                }
            }
        }

        if (win.CloseHandle(snapshot) == 0) {
            log.err("Failed to close snapshot, error code: {}", .{win.GetLastError()});
            return EcoErrors.WINAPI;
        }

        // TODO: Could use a coalescing timer.
        win.Sleep(std.time.ms_per_min * 5);
    }
}
