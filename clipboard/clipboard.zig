const std = @import("std");

const win = @cImport({
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");

    @cInclude("windows.h");
});

var suppress_next_change = std.atomic.Value(bool).init(false);

fn writeStdout(data: []const u8) !void {
    const stdout = std.io.getStdOut();
    try stdout.writeAll(data);
}

// ---------------------------------------------------------------------
// Text (CF_UNICODETEXT)
// ---------------------------------------------------------------------

fn writeClipboardText(text: []const u8) !void {
    if (win.OpenClipboard(null) == 0) {
        return error.OpenClipboardFailed;
    }

    defer _ = win.CloseClipboard();

    if (win.EmptyClipboard() == 0) {
        return error.EmptyClipboardFailed;
    }

    // UTF-8 -> UTF-16
    const wide_len = win.MultiByteToWideChar(
        win.CP_UTF8,
        0,
        text.ptr,
        @intCast(text.len),
        null,
        0,
    );

    if (wide_len <= 0) {
        return error.Utf8ConversionFailed;
    }

    const allocator = std.heap.page_allocator;

    const wide = try allocator.alloc(
        u16,
        @intCast(wide_len + 1),
    );

    defer allocator.free(wide);

    const converted = win.MultiByteToWideChar(
        win.CP_UTF8,
        0,
        text.ptr,
        @intCast(text.len),
        @ptrCast(wide.ptr),
        wide_len,
    );

    if (converted <= 0) {
        return error.Utf8ConversionFailed;
    }

    wide[@intCast(wide_len)] = 0;

    const bytes =
        (@as(usize, @intCast(wide_len)) + 1) *
        @sizeOf(u16);

    const hmem = win.GlobalAlloc(
        win.GMEM_MOVEABLE,
        bytes,
    );

    if (hmem == null) {
        return error.GlobalAllocFailed;
    }

    const ptr = win.GlobalLock(hmem);

    if (ptr == null) {
        _ = win.GlobalFree(hmem);
        return error.GlobalLockFailed;
    }

    const dest: [*]u16 =
        @ptrCast(@alignCast(ptr));

    @memcpy(
        dest[0 .. @intCast(wide_len + 1)],
        wide[0 .. @intCast(wide_len + 1)],
    );

    _ = win.GlobalUnlock(hmem);

    if (win.SetClipboardData(
        win.CF_UNICODETEXT,
        hmem,
    ) == null) {
        _ = win.GlobalFree(hmem);
        return error.SetClipboardFailed;
    }
}

fn readClipboardText(
    allocator: std.mem.Allocator,
) ![]u8 {
    if (win.OpenClipboard(null) == 0) {
        return error.OpenClipboardFailed;
    }

    defer _ = win.CloseClipboard();

    const handle =
        win.GetClipboardData(win.CF_UNICODETEXT);

    if (handle == null) {
        return error.NoTextClipboard;
    }

    const ptr = win.GlobalLock(handle);

    if (ptr == null) {
        return error.GlobalLockFailed;
    }

    defer _ = win.GlobalUnlock(handle);

    const wide_ptr: [*:0]const u16 =
        @ptrCast(@alignCast(ptr));

    const wide = std.mem.span(wide_ptr);

    const max_utf8 =
        wide.len * 3 + 1;

    const result =
        try allocator.alloc(u8, max_utf8);

    const utf8_len =
        std.unicode.utf16LeToUtf8(
            result,
            wide,
        ) catch {
            allocator.free(result);
            return error.Utf16ConversionFailed;
        };

    return result[0..utf8_len];
}

// ---------------------------------------------------------------------
// Image (CF_DIB) — raw passthrough. Zig never decodes pixels; it just
// relays the exact bytes Windows itself uses for CF_DIB
// (BITMAPINFOHEADER + pixel data). Go owns turning that into/from PNG
// for the network hop.
// ---------------------------------------------------------------------

fn readClipboardImage(
    allocator: std.mem.Allocator,
) ![]u8 {
    if (win.OpenClipboard(null) == 0) {
        return error.OpenClipboardFailed;
    }

    defer _ = win.CloseClipboard();

    const handle = win.GetClipboardData(win.CF_DIB);

    if (handle == null) {
        return error.NoImageClipboard;
    }

    const size: usize = @intCast(win.GlobalSize(handle));

    if (size == 0) {
        return error.GlobalSizeFailed;
    }

    const ptr = win.GlobalLock(handle);

    if (ptr == null) {
        return error.GlobalLockFailed;
    }

    defer _ = win.GlobalUnlock(handle);

    const src: [*]const u8 = @ptrCast(ptr);

    const result = try allocator.alloc(u8, size);

    @memcpy(result, src[0..size]);

    return result;
}

fn writeClipboardImage(data: []const u8) !void {
    if (win.OpenClipboard(null) == 0) {
        return error.OpenClipboardFailed;
    }

    defer _ = win.CloseClipboard();

    if (win.EmptyClipboard() == 0) {
        return error.EmptyClipboardFailed;
    }

    const hmem = win.GlobalAlloc(
        win.GMEM_MOVEABLE,
        data.len,
    );

    if (hmem == null) {
        return error.GlobalAllocFailed;
    }

    const ptr = win.GlobalLock(hmem);

    if (ptr == null) {
        _ = win.GlobalFree(hmem);
        return error.GlobalLockFailed;
    }

    const dest: [*]u8 = @ptrCast(ptr);

    @memcpy(dest[0..data.len], data);

    _ = win.GlobalUnlock(hmem);

    if (win.SetClipboardData(
        win.CF_DIB,
        hmem,
    ) == null) {
        _ = win.GlobalFree(hmem);
        return error.SetClipboardFailed;
    }
}

// ---------------------------------------------------------------------
// IPC framing: "<TAG> <format> <size>\n" followed by exactly <size>
// raw bytes — no base64. format is "text" or "image", matching Go's
// protocol.FormatText / protocol.FormatImage exactly (case matters:
// Go compares these strings directly).
// ---------------------------------------------------------------------

fn sendClipboardEvent(
    format: []const u8,
    data: []const u8,
) !void {
    var header_buf: [64]u8 = undefined;

    const header = try std.fmt.bufPrint(
        &header_buf,
        "CLIPBOARD {s} {d}\n",
        .{ format, data.len },
    );

    try writeStdout(header);
    try writeStdout(data);
}

fn processCommand(line: []const u8, stdin: anytype) !void {
    const prefix = "SET ";

    if (!std.mem.startsWith(u8, line, prefix)) {
        return;
    }

    var it = std.mem.splitScalar(u8, line[prefix.len..], ' ');

    const format = it.next() orelse return error.MalformedSetCommand;
    const size_str = it.next() orelse return error.MalformedSetCommand;
    const size = try std.fmt.parseInt(usize, size_str, 10);

    const allocator = std.heap.page_allocator;

    const data = try allocator.alloc(u8, size);
    defer allocator.free(data);

    try stdin.readNoEof(data);

    // Tell the clipboard watcher that the next clipboard change is
    // caused by us, so it isn't echoed back out over the network.
    suppress_next_change.store(
        true,
        .seq_cst,
    );

    if (std.mem.eql(u8, format, "image")) {
        try writeClipboardImage(data);
    } else {
        try writeClipboardText(data);
    }
}

fn stdinThread() void {
    var stdin = std.io.getStdIn().reader();

    var header_buf: [256]u8 = undefined;

    while (true) {
        const line = stdin.readUntilDelimiterOrEof(
            &header_buf,
            '\n',
        ) catch {
            return;
        };

        if (line == null) {
            return;
        }

        processCommand(line.?, stdin) catch |err| {
            std.debug.print("SET command failed: {}\n", .{err});
        };
    }
}

// ---------------------------------------------------------------------
// Clipboard change notification (event-driven, no polling)
// ---------------------------------------------------------------------

// wndProc handles messages for our hidden listener window. The only
// one we care about is WM_CLIPBOARDUPDATE, delivered the instant the
// clipboard changes — no polling required.
fn wndProc(
    hwnd: win.HWND,
    msg: win.UINT,
    wparam: win.WPARAM,
    lparam: win.LPARAM,
) callconv(.C) win.LRESULT {
    if (msg == win.WM_CLIPBOARDUPDATE) {
        // If this change came from our own remote SET command, don't
        // send it back over the network.
        if (suppress_next_change.swap(
            false,
            .seq_cst,
        )) {
            return 0;
        }

        const allocator = std.heap.page_allocator;

        // A copied image exposes CF_DIB; check that first, then fall
        // back to text. Anything else (files, RTF, etc.) is ignored.
        if (win.IsClipboardFormatAvailable(win.CF_DIB) != 0) {
            if (readClipboardImage(allocator)) |data| {
                defer allocator.free(data);

                sendClipboardEvent("image", data) catch {};
            } else |_| {}
        } else if (win.IsClipboardFormatAvailable(win.CF_UNICODETEXT) != 0) {
            if (readClipboardText(allocator)) |text| {
                defer allocator.free(text);

                sendClipboardEvent("text", text) catch {};
            } else |_| {}
        }

        return 0;
    }

    return win.DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn main() !void {
    try writeStdout("READY\n");

    const thread =
        try std.Thread.spawn(
            .{},
            stdinThread,
            .{},
        );

    thread.detach();

    const class_name =
        std.unicode.utf8ToUtf16LeStringLiteral("ZigoclipListener");

    var wc = std.mem.zeroes(win.WNDCLASSEXW);
    wc.cbSize = @sizeOf(win.WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = win.GetModuleHandleW(null);
    wc.lpszClassName = class_name;

    if (win.RegisterClassExW(&wc) == 0) {
        return error.RegisterClassFailed;
    }

    // Passing null (rather than HWND_MESSAGE) sidesteps a Zig 0.13
    // cimport bug casting that sentinel constant. This just creates an
    // ordinary top-level window instead of a message-only one — since
    // we never call ShowWindow, it's never actually shown, and it
    // still receives WM_CLIPBOARDUPDATE the same way.
    const hwnd = win.CreateWindowExW(
        0,
        class_name,
        class_name,
        0,
        0,
        0,
        0,
        0,
        null,
        null,
        wc.hInstance,
        null,
    );

    if (hwnd == null) {
        return error.CreateWindowFailed;
    }

    if (win.AddClipboardFormatListener(hwnd) == 0) {
        return error.AddClipboardListenerFailed;
    }

    // Blocks until a message arrives — no busy-waiting, no polling
    // interval, and updates are handled the instant they happen.
    var msg: win.MSG = undefined;

    while (win.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = win.TranslateMessage(&msg);
        _ = win.DispatchMessageW(&msg);
    }
}