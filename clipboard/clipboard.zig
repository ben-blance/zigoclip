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

fn writeClipboardText(text: []const u8) !void {
    if (win.OpenClipboard(null) == 0) {
        return error.OpenClipboardFailed;
    }

    defer _ = win.CloseClipboard();

    if (win.EmptyClipboard() == 0) {
        return error.EmptyClipboardFailed;
    }

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

fn sendClipboardEvent(
    text: []const u8,
) !void {
    const allocator =
        std.heap.page_allocator;

    const encoded_len =
        std.base64.standard.Encoder.calcSize(
            text.len,
        );

    const encoded =
        try allocator.alloc(
            u8,
            encoded_len,
        );

    defer allocator.free(encoded);

    _ = std.base64.standard.Encoder.encode(
        encoded,
        text,
    );

    try writeStdout("CLIPBOARD ");
    try writeStdout(encoded);
    try writeStdout("\n");
}

fn processCommand(
    line: []const u8,
) !void {
    const prefix = "SET ";

    if (!std.mem.startsWith(
        u8,
        line,
        prefix,
    )) {
        return;
    }

    const encoded =
        line[prefix.len..];

    const allocator =
        std.heap.page_allocator;

    const decoded_len =
        try std.base64.standard.Decoder.calcSizeForSlice(
            encoded,
        );

    const decoded =
        try allocator.alloc(
            u8,
            decoded_len,
        );

    defer allocator.free(decoded);

    try std.base64.standard.Decoder.decode(
        decoded,
        encoded,
    );

    suppress_next_change.store(
        true,
        .seq_cst,
    );

    try writeClipboardText(decoded);
}

fn stdinThread() void {
    var stdin = std.io.getStdIn().reader();

    var buffer: [8192]u8 = undefined;

    while (true) {
        const line =
            stdin.readUntilDelimiterOrEof(
                &buffer,
                '\n',
            ) catch {
                return;
            };

        if (line == null) {
            return;
        }

        processCommand(line.?) catch {};
    }
}

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

        if (readClipboardText(
            std.heap.page_allocator,
        )) |text| {
            defer std.heap.page_allocator.free(text);

            sendClipboardEvent(text) catch {};
        } else |_| {}

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