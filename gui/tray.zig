// Zigoclip tray + settings window
//
// Zig 0.13 / MinGW / native Win32.
//
// UI target:
//   - compact dark-mode settings panel with a cyan accent
//   - flat borderless custom title bar (minimize + close only)
//   - "Launch on Windows startup" row with toggle
//   - "Manage access" row styled and behaving like a real button
//   - GitHub source-code card using the bundled github.ico
//   - hover feedback everywhere something is clickable
//
// Runtime responsibilities:
//   - launch zigoclip.exe
//   - supervise zigoclip.exe -> clipboard.exe with a Job Object
//   - kill the whole job when Exit is chosen
//   - provide a system tray icon
//   - provide Start with Windows
//   - open Access Management
//
// Expected layout on disk (assets sit next to the built exe):
//
//   tray.exe
//   assets/github.ico
//
// Build:
//   zig build-exe gui/tray.zig -lc -luser32 -lshell32 -ladvapi32 -lgdi32 --subsystem windows -femit-bin=tray.exe

const std = @import("std");

const win = @cImport({
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");

    @cInclude("windows.h");
    @cInclude("shellapi.h");
});

// =====================================================================
// Application constants
// =====================================================================

const WM_TRAYICON = win.WM_APP + 1;

const ID_STARTUP_TOGGLE: u16 = 1001;
const ID_ACCESS_MANAGEMENT: u16 = 1002;
const ID_GITHUB: u16 = 1003;
const ID_OPEN: u16 = 1004;
const ID_EXIT: u16 = 1005;

const ACCESS_MANAGEMENT_PORT = 42426;

// Change this to your actual repository.
const GITHUB_URL = "https://github.com/";

const RUN_KEY_PATH =
    "Software\\Microsoft\\Windows\\CurrentVersion\\Run";

const RUN_VALUE_NAME = "Zigoclip";

// =====================================================================
// Custom window constants
// =====================================================================
//
// This is a small settings popover, not an application window — sized
// to fit exactly what it contains and nothing more.
//

const WINDOW_WIDTH = 420;
const WINDOW_HEIGHT = 312;
const TITLEBAR_HEIGHT = 44;
const CORNER_RADIUS = 16;

const PAD = 20;

// Title-bar buttons (minimize + close only).
const TITLE_MIN_RIGHT = WINDOW_WIDTH - 40;
const TITLE_MIN_LEFT = TITLE_MIN_RIGHT - 40;

const TITLE_CLOSE_LEFT = WINDOW_WIDTH - 40;
const TITLE_CLOSE_RIGHT = WINDOW_WIDTH;

// Startup toggle.
const TOGGLE_W = 44;
const TOGGLE_H = 22;
const TOGGLE_RIGHT = WINDOW_WIDTH - PAD;
const TOGGLE_LEFT = TOGGLE_RIGHT - TOGGLE_W;
const TOGGLE_TOP = 64;
const TOGGLE_BOTTOM = TOGGLE_TOP + TOGGLE_H;

const DIVIDER_Y = 110;

// "Manage access" row — a real button-looking row, not a floating link.
const ACCESS_ROW_LEFT = PAD;
const ACCESS_ROW_RIGHT = WINDOW_WIDTH - PAD;
const ACCESS_ROW_TOP = 126;
const ACCESS_ROW_BOTTOM = ACCESS_ROW_TOP + 46;

// GitHub source card.
const CARD_LEFT = PAD;
const CARD_RIGHT = WINDOW_WIDTH - PAD;
const CARD_TOP = 188;
const CARD_BOTTOM = CARD_TOP + 60;

const GITHUB_ICON_SIZE = 28;

// =====================================================================
// Colors — dark mode with a cyan accent
// =====================================================================
//
// COLORREF is encoded as 0x00BBGGRR.
//

fn rgb(r: u8, g: u8, b: u8) win.DWORD {
    return @as(win.DWORD, r) |
        (@as(win.DWORD, g) << 8) |
        (@as(win.DWORD, b) << 16);
}

const COLOR_BG = rgb(10, 13, 15); // main body background
const COLOR_BG_2 = rgb(15, 19, 22); // title bar background
const COLOR_CYAN = rgb(34, 211, 238); // primary accent (cyan-400)
const COLOR_CYAN_DARK = rgb(8, 120, 134); // dim accent / outer border
const COLOR_WHITE = rgb(240, 245, 247);
const COLOR_TEXT = rgb(222, 230, 233);
const COLOR_MUTED = rgb(120, 134, 139);
const COLOR_CARD = rgb(17, 22, 25);
const COLOR_CARD_HOVER = rgb(24, 32, 36);
const COLOR_BORDER = rgb(33, 41, 44);
const COLOR_OFF = rgb(46, 54, 58);
const COLOR_KNOB = rgb(235, 240, 242);
const COLOR_TITLE_BTN_HOVER = rgb(28, 36, 40);
const COLOR_CLOSE_HOVER_BG = rgb(64, 28, 28);
const COLOR_CLOSE_HOVER_TEXT = rgb(235, 100, 100);

// =====================================================================
// Win32 compatibility bindings
// =====================================================================
//
// Zig 0.13 + MinGW has trouble with some predefined pointer-shaped
// constants coming through cImport.
//
// HKEY_CURRENT_USER:
//     0x80000001
//
// IDI_APPLICATION:
//     32512
//
// IDC_ARROW:
//     32512
//
// IDC_HAND:
//     32649
//

const HKEY_CURRENT_USER: usize = 0x80000001;
const IDI_APPLICATION: usize = 32512;
const IDC_ARROW: usize = 32512;
const IDC_HAND: usize = 32649;

const DI_NORMAL: win.UINT = 3;

extern "advapi32" fn RegOpenKeyExW(
    hKey: usize,
    lpSubKey: [*:0]const u16,
    ulOptions: win.DWORD,
    samDesired: win.DWORD,
    phkResult: *win.HKEY,
) callconv(.C) win.LONG;

// Use C-compatible opaque pointer for HINSTANCE.
// Return HICON directly rather than ?HICON because Zig 0.13's C ABI
// checker rejects optional pointer returns in extern declarations.
extern "user32" fn LoadIconW(
    hInstance: ?*anyopaque,
    lpIconName: usize,
) callconv(.C) win.HICON;

extern "user32" fn LoadCursorW(
    hInstance: ?*anyopaque,
    lpCursorName: usize,
) callconv(.C) win.HCURSOR;

extern "user32" fn LookupIconIdFromDirectoryEx(
    presbits: [*]const u8,
    fIcon: win.BOOL,
    cxDesired: i32,
    cyDesired: i32,
    flags: win.UINT,
) callconv(.C) i32;

extern "user32" fn CreateIconFromResourceEx(
    presbits: [*]const u8,
    dwResSize: win.DWORD,
    fIcon: win.BOOL,
    dwVer: win.DWORD,
    cxDesired: i32,
    cyDesired: i32,
    flags: win.UINT,
) callconv(.C) win.HICON;

// =====================================================================
// Global state
// =====================================================================

var tray_icon_data: win.NOTIFYICONDATAW = undefined;

var child_process: ?win.HANDLE = null;
var job_object: ?win.HANDLE = null;

var main_hwnd: ?win.HWND = null;

var github_icon: ?win.HICON = null;

var quit_requested = false;

const HoverZone = enum {
    none,
    minimize,
    close,
    toggle,
    access_row,
    card,
};

var hover_zone: HoverZone = .none;
var mouse_tracking = false;

// =====================================================================
// String helpers
// =====================================================================

fn wide(comptime s: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

// =====================================================================
// Coordinate helpers
// =====================================================================

fn signedLowWord(value: win.LPARAM) i32 {
    const raw: usize = @bitCast(value);
    const bits: u16 = @truncate(raw & 0xFFFF);
    const signed: i16 = @bitCast(bits);
    return @intCast(signed);
}

fn signedHighWord(value: win.LPARAM) i32 {
    const raw: usize = @bitCast(value);
    const bits: u16 = @truncate((raw >> 16) & 0xFFFF);
    const signed: i16 = @bitCast(bits);
    return @intCast(signed);
}

fn pointInRect(
    x: i32,
    y: i32,
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
) bool {
    return x >= left and
        x < right and
        y >= top and
        y < bottom;
}

// Single source of truth for "what is under the cursor". Used by
// hover tracking, click handling, cursor selection, and title-bar
// hit testing so all four stay perfectly in sync.
fn hitZone(x: i32, y: i32) HoverZone {
    if (y >= 0 and y < TITLEBAR_HEIGHT) {
        if (pointInRect(x, y, TITLE_MIN_LEFT, 0, TITLE_MIN_RIGHT, TITLEBAR_HEIGHT)) {
            return .minimize;
        }

        if (pointInRect(x, y, TITLE_CLOSE_LEFT, 0, TITLE_CLOSE_RIGHT, TITLEBAR_HEIGHT)) {
            return .close;
        }

        return .none;
    }

    if (pointInRect(x, y, TOGGLE_LEFT - 8, TOGGLE_TOP - 8, TOGGLE_RIGHT + 8, TOGGLE_BOTTOM + 8)) {
        return .toggle;
    }

    if (pointInRect(x, y, ACCESS_ROW_LEFT, ACCESS_ROW_TOP, ACCESS_ROW_RIGHT, ACCESS_ROW_BOTTOM)) {
        return .access_row;
    }

    if (pointInRect(x, y, CARD_LEFT, CARD_TOP, CARD_RIGHT, CARD_BOTTOM)) {
        return .card;
    }

    return .none;
}

// =====================================================================
// "Start with Windows"
// =====================================================================

fn isAutostartEnabled() bool {
    var hkey: win.HKEY = undefined;

    if (RegOpenKeyExW(
        HKEY_CURRENT_USER,
        wide(RUN_KEY_PATH),
        0,
        win.KEY_QUERY_VALUE,
        &hkey,
    ) != 0) {
        return false;
    }

    defer _ = win.RegCloseKey(hkey);

    const status = win.RegQueryValueExW(
        hkey,
        wide(RUN_VALUE_NAME),
        null,
        null,
        null,
        null,
    );

    return status == 0;
}

fn getExePathW(buf: []u16) usize {
    return @intCast(
        win.GetModuleFileNameW(
            null,
            buf.ptr,
            @intCast(buf.len),
        ),
    );
}

fn setAutostartEnabled(enabled: bool) void {
    var hkey: win.HKEY = undefined;

    if (RegOpenKeyExW(
        HKEY_CURRENT_USER,
        wide(RUN_KEY_PATH),
        0,
        win.KEY_SET_VALUE,
        &hkey,
    ) != 0) {
        return;
    }

    defer _ = win.RegCloseKey(hkey);

    if (!enabled) {
        _ = win.RegDeleteValueW(
            hkey,
            wide(RUN_VALUE_NAME),
        );

        return;
    }

    var exe_path: [win.MAX_PATH]u16 = undefined;

    const exe_len =
        getExePathW(&exe_path);

    var quoted: [win.MAX_PATH + 3]u16 = undefined;

    quoted[0] = '"';

    @memcpy(
        quoted[1 .. 1 + exe_len],
        exe_path[0..exe_len],
    );

    quoted[1 + exe_len] = '"';
    quoted[2 + exe_len] = 0;

    const value_len_bytes: win.DWORD =
        @intCast((exe_len + 3) * @sizeOf(u16));

    _ = win.RegSetValueExW(
        hkey,
        wide(RUN_VALUE_NAME),
        0,
        win.REG_SZ,
        @ptrCast(&quoted),
        value_len_bytes,
    );
}

// =====================================================================
// Executable directory
// =====================================================================

fn computeExeDir(buf: []u16) []const u16 {
    const full_len = getExePathW(buf);

    var cut = full_len;

    while (cut > 0) : (cut -= 1) {
        if (buf[cut - 1] == '\\') {
            break;
        }
    }

    // Includes the trailing backslash.
    return buf[0..cut];
}

// =====================================================================
// GitHub icon
// =====================================================================

// Compiled directly into the exe — no need to ship gui/assets alongside
// tray.exe at runtime. Path is resolved at compile time relative to
// this source file (gui/tray.zig), so it points at gui/assets/github.ico.
const GITHUB_ICON_DATA = @embedFile("assets/github.ico");

fn loadGithubIcon() void {
    // A .ico file can bundle several sizes; ask Windows which one in
    // the blob best matches the size we want, then materialize it.
    const offset = LookupIconIdFromDirectoryEx(
        GITHUB_ICON_DATA.ptr,
        1, // TRUE: this is an icon, not a cursor
        GITHUB_ICON_SIZE,
        GITHUB_ICON_SIZE,
        0,
    );

    if (offset <= 0) {
        return;
    }

    const start: usize = @intCast(offset);

    const icon = CreateIconFromResourceEx(
        GITHUB_ICON_DATA[start..].ptr,
        @intCast(GITHUB_ICON_DATA.len - start),
        1, // TRUE: icon
        0x00030000, // resource version 3.0
        GITHUB_ICON_SIZE,
        GITHUB_ICON_SIZE,
        0,
    );

    if (icon != null) {
        github_icon = icon;
    }
}

// =====================================================================
// Job object
// =====================================================================
//
// JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE means that when the final job
// handle closes, Windows terminates processes belonging to that job.
//
// This gives us:
//
//     tray.exe
//         |
//         +--> zigoclip.exe
//                  |
//                  +--> clipboard.exe
//
// Closing the job tears down the tree together.
//

fn createJobObject() ?win.HANDLE {
    const job =
        win.CreateJobObjectW(null, null);

    if (job == null) {
        return null;
    }

    var info =
        std.mem.zeroes(
            win.JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        );

    info.BasicLimitInformation.LimitFlags =
        win.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

    const result =
        win.SetInformationJobObject(
            job,
            win.JobObjectExtendedLimitInformation,
            &info,
            @sizeOf(
                win.JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            ),
        );

    if (result == 0) {
        _ = win.CloseHandle(job);
        return null;
    }

    return job;
}

// =====================================================================
// Agent process
// =====================================================================

fn spawnAgent(exe_dir: []const u16) !win.HANDLE {
    const agent_name =
        wide("zigoclip.exe");

    const agent_name_len =
        std.mem.len(agent_name);

    var cmd_buf:
        [win.MAX_PATH + 32]u16 = undefined;

    var i: usize = 0;

    cmd_buf[i] = '"';
    i += 1;

    @memcpy(
        cmd_buf[i .. i + exe_dir.len],
        exe_dir,
    );

    i += exe_dir.len;

    @memcpy(
        cmd_buf[i .. i + agent_name_len],
        agent_name[0..agent_name_len],
    );

    i += agent_name_len;

    cmd_buf[i] = '"';
    i += 1;

    cmd_buf[i] = 0;

    var dir_buf:
        [win.MAX_PATH]u16 = undefined;

    @memcpy(
        dir_buf[0..exe_dir.len],
        exe_dir,
    );

    dir_buf[exe_dir.len] = 0;

    var startup_info =
        std.mem.zeroes(
            win.STARTUPINFOW,
        );

    startup_info.cb =
        @sizeOf(win.STARTUPINFOW);

    var process_info:
        win.PROCESS_INFORMATION = undefined;

    const created =
        win.CreateProcessW(
            null,
            cmd_buf[0..].ptr,
            null,
            null,
            0,
            win.CREATE_NO_WINDOW |
                win.CREATE_SUSPENDED,
            null,
            dir_buf[0..].ptr,
            &startup_info,
            &process_info,
        );

    if (created == 0) {
        return error.SpawnFailed;
    }

    // IMPORTANT:
    //
    // Assign while the process is still suspended so zigoclip.exe
    // cannot start clipboard.exe before entering the job.
    if (job_object) |job| {
        if (win.AssignProcessToJobObject(
            job,
            process_info.hProcess,
        ) == 0) {
            _ = win.TerminateProcess(
                process_info.hProcess,
                1,
            );

            _ = win.CloseHandle(
                process_info.hThread,
            );

            _ = win.CloseHandle(
                process_info.hProcess,
            );

            return error.AssignJobFailed;
        }
    }

    const resume_result =
        win.ResumeThread(
            process_info.hThread,
        );

    // ResumeThread returns 0xFFFFFFFF on failure.
    if (resume_result ==
        std.math.maxInt(win.DWORD))
    {
        _ = win.TerminateProcess(
            process_info.hProcess,
            1,
        );

        _ = win.CloseHandle(
            process_info.hThread,
        );

        _ = win.CloseHandle(
            process_info.hProcess,
        );

        return error.ResumeFailed;
    }

    _ = win.CloseHandle(
        process_info.hThread,
    );

    return process_info.hProcess;
}

// =====================================================================
// URLs
// =====================================================================

fn openAccessManagement() void {
    _ = win.ShellExecuteW(
        null,
        wide("open"),
        wide("http://127.0.0.1:42426"),
        null,
        null,
        win.SW_SHOWNORMAL,
    );
}

fn openGithub() void {
    _ = win.ShellExecuteW(
        null,
        wide("open"),
        wide(GITHUB_URL),
        null,
        null,
        win.SW_SHOWNORMAL,
    );
}

// =====================================================================
// Small GDI drawing helpers
// =====================================================================

fn fillRect(
    hdc: win.HDC,
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    color: win.DWORD,
) void {
    var rect = win.RECT{
        .left = left,
        .top = top,
        .right = right,
        .bottom = bottom,
    };

    const brush =
        win.CreateSolidBrush(color);

    if (brush != null) {
        _ = win.FillRect(
            hdc,
            &rect,
            brush,
        );

        _ = win.DeleteObject(
            @ptrCast(brush),
        );
    }
}

fn fillRoundRect(
    hdc: win.HDC,
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    radius: i32,
    color: win.DWORD,
) void {
    const region =
        win.CreateRoundRectRgn(
            left,
            top,
            right,
            bottom,
            radius,
            radius,
        );

    if (region == null) {
        fillRect(
            hdc,
            left,
            top,
            right,
            bottom,
            color,
        );

        return;
    }

    const brush =
        win.CreateSolidBrush(color);

    if (brush != null) {
        _ = win.FillRgn(
            hdc,
            region,
            brush,
        );

        _ = win.DeleteObject(
            @ptrCast(brush),
        );
    }

    _ = win.DeleteObject(
        @ptrCast(region),
    );
}

fn frameRoundRect(
    hdc: win.HDC,
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    radius: i32,
    color: win.DWORD,
) void {
    const region =
        win.CreateRoundRectRgn(
            left,
            top,
            right,
            bottom,
            radius,
            radius,
        );

    if (region == null) {
        return;
    }

    const brush =
        win.CreateSolidBrush(color);

    if (brush != null) {
        _ = win.FrameRgn(
            hdc,
            region,
            brush,
            1,
            1,
        );

        _ = win.DeleteObject(
            @ptrCast(brush),
        );
    }

    _ = win.DeleteObject(
        @ptrCast(region),
    );
}

fn fillEllipse(
    hdc: win.HDC,
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    color: win.DWORD,
) void {
    const region =
        win.CreateEllipticRgn(
            left,
            top,
            right,
            bottom,
        );

    if (region == null) {
        return;
    }

    const brush =
        win.CreateSolidBrush(color);

    if (brush != null) {
        _ = win.FillRgn(
            hdc,
            region,
            brush,
        );

        _ = win.DeleteObject(
            @ptrCast(brush),
        );
    }

    _ = win.DeleteObject(
        @ptrCast(region),
    );
}

// A real diagonal X, drawn with a pen rather than approximated with
// axis-aligned rectangles — used for the close button.
fn drawXIcon(
    hdc: win.HDC,
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    thickness: i32,
    color: win.DWORD,
) void {
    const pen =
        win.CreatePen(
            0, // PS_SOLID
            thickness,
            color,
        );

    if (pen == null) {
        return;
    }

    const old_pen =
        win.SelectObject(
            hdc,
            @ptrCast(pen),
        );

    _ = win.MoveToEx(hdc, left, top, null);
    _ = win.LineTo(hdc, right, bottom);

    _ = win.MoveToEx(hdc, right, top, null);
    _ = win.LineTo(hdc, left, bottom);

    _ = win.SelectObject(
        hdc,
        old_pen,
    );

    _ = win.DeleteObject(
        @ptrCast(pen),
    );
}

// A ">" chevron drawn as a single two-segment polyline — used to mark
// rows as navigable/clickable instead of a plain ">" character.
fn drawChevronRight(
    hdc: win.HDC,
    cx: i32,
    cy: i32,
    size: i32,
    thickness: i32,
    color: win.DWORD,
) void {
    const pen =
        win.CreatePen(
            0, // PS_SOLID
            thickness,
            color,
        );

    if (pen == null) {
        return;
    }

    const old_pen =
        win.SelectObject(
            hdc,
            @ptrCast(pen),
        );

    _ = win.MoveToEx(hdc, cx - @divTrunc(size, 2), cy - size, null);
    _ = win.LineTo(hdc, cx + @divTrunc(size, 2), cy);
    _ = win.LineTo(hdc, cx - @divTrunc(size, 2), cy + size);

    _ = win.SelectObject(
        hdc,
        old_pen,
    );

    _ = win.DeleteObject(
        @ptrCast(pen),
    );
}

// =====================================================================
// Text drawing
// =====================================================================

fn drawText(
    hdc: win.HDC,
    text: [*:0]const u16,
    x: i32,
    y: i32,
    size: i32,
    weight: i32,
    color: win.DWORD,
) void {
    const font =
        win.CreateFontW(
            -size,
            0,
            0,
            0,
            weight,
            0,
            0,
            0,
            1, // DEFAULT_CHARSET
            0, // OUT_DEFAULT_PRECIS
            0, // CLIP_DEFAULT_PRECIS
            5, // CLEARTYPE_QUALITY
            34, // VARIABLE_PITCH | FF_SWISS
            wide("Segoe UI"),
        );

    const old_font =
        win.SelectObject(
            hdc,
            @ptrCast(font),
        );

    _ = win.SetBkMode(
        hdc,
        1, // TRANSPARENT
    );

    _ = win.SetTextColor(
        hdc,
        color,
    );

    _ = win.TextOutW(
        hdc,
        x,
        y,
        text,
        @intCast(std.mem.len(text)),
    );

    _ = win.SelectObject(
        hdc,
        old_font,
    );

    _ = win.DeleteObject(
        @ptrCast(font),
    );
}

// =====================================================================
// Zigoclip logo
// =====================================================================

fn drawLogo(
    hdc: win.HDC,
    x: i32,
    y: i32,
) void {
    const c = COLOR_CYAN;

    // Dashed rounded-square approximation, 24x24.
    //
    // Top.
    fillRoundRect(hdc, x + 3, y, x + 10, y + 2, 1, c);
    fillRoundRect(hdc, x + 14, y, x + 21, y + 2, 1, c);

    // Bottom.
    fillRoundRect(hdc, x + 3, y + 22, x + 10, y + 24, 1, c);
    fillRoundRect(hdc, x + 14, y + 22, x + 21, y + 24, 1, c);

    // Left.
    fillRoundRect(hdc, x, y + 3, x + 2, y + 10, 1, c);
    fillRoundRect(hdc, x, y + 14, x + 2, y + 21, 1, c);

    // Right.
    fillRoundRect(hdc, x + 22, y + 3, x + 24, y + 10, 1, c);
    fillRoundRect(hdc, x + 22, y + 14, x + 24, y + 21, 1, c);
}

// =====================================================================
// Main UI painting
// =====================================================================

fn paintWindow(
    hwnd: win.HWND,
    hdc: win.HDC,
) void {
    var client: win.RECT = undefined;

    _ = win.GetClientRect(
        hwnd,
        &client,
    );

    const width =
        client.right - client.left;

    const height =
        client.bottom - client.top;

    // ---------------------------------------------------------------
    // Outer 1px accent border, dark body fill
    // ---------------------------------------------------------------

    fillRect(
        hdc,
        0,
        0,
        width,
        height,
        COLOR_CYAN_DARK,
    );

    fillRect(
        hdc,
        1,
        1,
        width - 1,
        height - 1,
        COLOR_BG,
    );

    // ---------------------------------------------------------------
    // Title bar
    // ---------------------------------------------------------------

    fillRect(
        hdc,
        1,
        1,
        width - 1,
        TITLEBAR_HEIGHT,
        COLOR_BG_2,
    );

    fillRect(
        hdc,
        1,
        TITLEBAR_HEIGHT,
        width - 1,
        TITLEBAR_HEIGHT + 1,
        COLOR_BORDER,
    );

    drawLogo(
        hdc,
        16,
        (TITLEBAR_HEIGHT - 24) >> 1,
    );

    drawText(
        hdc,
        wide("Zigoclip"),
        48,
        13,
        15,
        500,
        COLOR_WHITE,
    );

    // ---------------------------------------------------------------
    // Window controls — Minimize + Close only, with hover feedback
    // ---------------------------------------------------------------

    if (hover_zone == .minimize) {
        fillRoundRect(
            hdc,
            TITLE_MIN_LEFT + 4,
            4,
            TITLE_MIN_RIGHT - 4,
            TITLEBAR_HEIGHT - 4,
            6,
            COLOR_TITLE_BTN_HOVER,
        );
    }

    fillRect(
        hdc,
        TITLE_MIN_LEFT + 13,
        TITLEBAR_HEIGHT / 2 - 1,
        TITLE_MIN_RIGHT - 13,
        TITLEBAR_HEIGHT / 2 + 1,
        COLOR_TEXT,
    );

    if (hover_zone == .close) {
        fillRoundRect(
            hdc,
            TITLE_CLOSE_LEFT + 4,
            4,
            TITLE_CLOSE_RIGHT - 4,
            TITLEBAR_HEIGHT - 4,
            6,
            COLOR_CLOSE_HOVER_BG,
        );
    }

    drawXIcon(
        hdc,
        TITLE_CLOSE_LEFT + 14,
        TITLEBAR_HEIGHT / 2 - 6,
        TITLE_CLOSE_RIGHT - 14,
        TITLEBAR_HEIGHT / 2 + 6,
        2,
        if (hover_zone == .close) COLOR_CLOSE_HOVER_TEXT else COLOR_TEXT,
    );

    // ---------------------------------------------------------------
    // Startup row
    // ---------------------------------------------------------------

    drawText(
        hdc,
        wide("Launch on startup"),
        PAD,
        60,
        16,
        600,
        COLOR_WHITE,
    );

    drawText(
        hdc,
        wide("Starts automatically when you sign in."),
        PAD,
        84,
        12,
        400,
        COLOR_MUTED,
    );

    const startup_enabled =
        isAutostartEnabled();

    const toggle_color =
        if (startup_enabled)
            COLOR_CYAN
        else
            COLOR_OFF;

    fillRoundRect(
        hdc,
        TOGGLE_LEFT,
        TOGGLE_TOP,
        TOGGLE_RIGHT,
        TOGGLE_BOTTOM,
        TOGGLE_H >> 1,
        toggle_color,
    );

    if (startup_enabled) {
        fillEllipse(
            hdc,
            TOGGLE_RIGHT - 20,
            TOGGLE_TOP + 3,
            TOGGLE_RIGHT - 3,
            TOGGLE_BOTTOM - 3,
            COLOR_KNOB,
        );
    } else {
        fillEllipse(
            hdc,
            TOGGLE_LEFT + 3,
            TOGGLE_TOP + 3,
            TOGGLE_LEFT + 20,
            TOGGLE_BOTTOM - 3,
            COLOR_KNOB,
        );
    }

    // ---------------------------------------------------------------
    // Divider
    // ---------------------------------------------------------------

    fillRect(
        hdc,
        PAD,
        DIVIDER_Y,
        WINDOW_WIDTH - PAD,
        DIVIDER_Y + 1,
        COLOR_BORDER,
    );

    // ---------------------------------------------------------------
    // "Manage access" row — now an actual button, not a floating link
    // ---------------------------------------------------------------

    const access_hovered = hover_zone == .access_row;

    fillRoundRect(
        hdc,
        ACCESS_ROW_LEFT,
        ACCESS_ROW_TOP,
        ACCESS_ROW_RIGHT,
        ACCESS_ROW_BOTTOM,
        10,
        if (access_hovered) COLOR_CARD_HOVER else COLOR_CARD,
    );

    frameRoundRect(
        hdc,
        ACCESS_ROW_LEFT,
        ACCESS_ROW_TOP,
        ACCESS_ROW_RIGHT,
        ACCESS_ROW_BOTTOM,
        10,
        if (access_hovered) COLOR_CYAN_DARK else COLOR_BORDER,
    );

    drawText(
        hdc,
        wide("Manage access"),
        ACCESS_ROW_LEFT + 16,
        ACCESS_ROW_TOP + 14,
        14,
        600,
        COLOR_TEXT,
    );

    drawChevronRight(
        hdc,
        ACCESS_ROW_RIGHT - 20,
        ACCESS_ROW_TOP + ((ACCESS_ROW_BOTTOM - ACCESS_ROW_TOP) >> 1),
        5,
        2,
        if (access_hovered) COLOR_CYAN else COLOR_MUTED,
    );

    // ---------------------------------------------------------------
    // GitHub/source card
    // ---------------------------------------------------------------

    const card_hovered = hover_zone == .card;

    fillRoundRect(
        hdc,
        CARD_LEFT,
        CARD_TOP,
        CARD_RIGHT,
        CARD_BOTTOM,
        10,
        if (card_hovered) COLOR_CARD_HOVER else COLOR_CARD,
    );

    frameRoundRect(
        hdc,
        CARD_LEFT,
        CARD_TOP,
        CARD_RIGHT,
        CARD_BOTTOM,
        10,
        if (card_hovered) COLOR_CYAN_DARK else COLOR_BORDER,
    );

    const icon_y = CARD_TOP + (((CARD_BOTTOM - CARD_TOP) - GITHUB_ICON_SIZE) >> 1);

    if (github_icon) |icon| {
        _ = win.DrawIconEx(
            hdc,
            CARD_LEFT + 16,
            icon_y,
            icon,
            GITHUB_ICON_SIZE,
            GITHUB_ICON_SIZE,
            0,
            null,
            DI_NORMAL,
        );
    } else {
        // Fallback placeholder if assets/github.ico wasn't found.
        fillEllipse(
            hdc,
            CARD_LEFT + 16,
            icon_y,
            CARD_LEFT + 16 + GITHUB_ICON_SIZE,
            icon_y + GITHUB_ICON_SIZE,
            COLOR_WHITE,
        );

        drawText(
            hdc,
            wide("GH"),
            CARD_LEFT + 22,
            icon_y + 6,
            11,
            700,
            COLOR_BG,
        );
    }

    drawText(
        hdc,
        wide("View source on GitHub"),
        CARD_LEFT + 16 + GITHUB_ICON_SIZE + 12,
        CARD_TOP + 14,
        14,
        600,
        if (card_hovered) COLOR_CYAN else COLOR_TEXT,
    );

    drawText(
        hdc,
        wide("Star it, file issues, or contribute"),
        CARD_LEFT + 16 + GITHUB_ICON_SIZE + 12,
        CARD_TOP + 34,
        11,
        400,
        COLOR_MUTED,
    );
}

// =====================================================================
// Rounded window region
// =====================================================================

fn updateWindowRegion(hwnd: win.HWND) void {
    if (win.IsZoomed(hwnd) != 0) {
        // No rounded corners when maximized (shouldn't normally
        // happen since the UI no longer exposes a maximize button,
        // but Windows snap gestures can still trigger it).
        _ = win.SetWindowRgn(
            hwnd,
            null,
            1,
        );

        return;
    }

    var rect: win.RECT = undefined;

    _ = win.GetClientRect(
        hwnd,
        &rect,
    );

    const width =
        rect.right - rect.left;

    const height =
        rect.bottom - rect.top;

    if (width <= 0 or height <= 0) {
        return;
    }

    const region =
        win.CreateRoundRectRgn(
            0,
            0,
            width + 1,
            height + 1,
            CORNER_RADIUS,
            CORNER_RADIUS,
        );

    if (region == null) {
        return;
    }

    // SetWindowRgn takes ownership of a successful region.
    if (win.SetWindowRgn(
        hwnd,
        region,
        1,
    ) == 0) {
        _ = win.DeleteObject(
            @ptrCast(region),
        );
    }
}

// =====================================================================
// Show / hide
// =====================================================================

fn showMainWindow() void {
    if (main_hwnd) |hwnd| {
        _ = win.ShowWindow(
            hwnd,
            win.SW_RESTORE,
        );

        _ = win.ShowWindow(
            hwnd,
            win.SW_SHOW,
        );

        _ = win.SetForegroundWindow(
            hwnd,
        );

        _ = win.UpdateWindow(
            hwnd,
        );
    }
}

fn hideMainWindow(hwnd: win.HWND) void {
    _ = win.ShowWindow(
        hwnd,
        win.SW_HIDE,
    );
}

// =====================================================================
// Tray icon
// =====================================================================

fn addTrayIcon(hwnd: win.HWND) void {
    tray_icon_data =
        std.mem.zeroes(
            win.NOTIFYICONDATAW,
        );

    tray_icon_data.cbSize =
        @sizeOf(win.NOTIFYICONDATAW);

    tray_icon_data.hWnd =
        hwnd;

    tray_icon_data.uID =
        1;

    tray_icon_data.uFlags =
        win.NIF_ICON |
        win.NIF_MESSAGE |
        win.NIF_TIP;

    tray_icon_data.uCallbackMessage =
        WM_TRAYICON;

    tray_icon_data.hIcon =
        LoadIconW(
            null,
            IDI_APPLICATION,
        );

    const tip =
        wide("Zigoclip");

    const tip_len =
        std.mem.len(tip);

    @memcpy(
        tray_icon_data.szTip[0..tip_len],
        tip[0..tip_len],
    );

    tray_icon_data.szTip[tip_len] = 0;

    _ = win.Shell_NotifyIconW(
        win.NIM_ADD,
        &tray_icon_data,
    );
}

// =====================================================================
// Tray popup menu
// =====================================================================

fn showTrayMenu(hwnd: win.HWND) void {
    const menu =
        win.CreatePopupMenu();

    if (menu == null) {
        return;
    }

    defer _ =
        win.DestroyMenu(menu);

    // Header.
    _ = win.AppendMenuW(
        menu,
        0x00000000,
        0,
        wide("Zigoclip"),
    );

    _ = win.AppendMenuW(
        menu,
        0x00000800,
        0,
        null,
    );

    // Open.
    _ = win.AppendMenuW(
        menu,
        0x00000000,
        ID_OPEN,
        wide("Open"),
    );

    // Startup.
    const startup_flags: win.UINT =
        if (isAutostartEnabled())
            0x00000008
        else
            0x00000000;

    _ = win.AppendMenuW(
        menu,
        startup_flags,
        ID_STARTUP_TOGGLE,
        wide("Start with Windows"),
    );

    _ = win.AppendMenuW(
        menu,
        0x00000800,
        0,
        null,
    );

    // Access management.
    _ = win.AppendMenuW(
        menu,
        0x00000000,
        ID_ACCESS_MANAGEMENT,
        wide("Access Management"),
    );

    _ = win.AppendMenuW(
        menu,
        0x00000800,
        0,
        null,
    );

    // Exit.
    _ = win.AppendMenuW(
        menu,
        0x00000000,
        ID_EXIT,
        wide("Exit"),
    );

    _ = win.SetForegroundWindow(
        hwnd,
    );

    var pt: win.POINT = undefined;

    _ = win.GetCursorPos(
        &pt,
    );

    _ = win.TrackPopupMenu(
        menu,
        win.TPM_RIGHTALIGN |
            win.TPM_BOTTOMALIGN,
        pt.x,
        pt.y,
        0,
        hwnd,
        null,
    );

    _ = win.PostMessageW(
        hwnd,
        win.WM_NULL,
        0,
        0,
    );
}

// =====================================================================
// Window hit testing
// =====================================================================
//
// Returning HTCAPTION makes the custom title bar draggable.
//
// The Windows docs specifically define HTCAPTION as the title-bar
// hit-test result. We keep the custom buttons as HTCLIENT so our
// WM_LBUTTONUP handler receives those clicks.
//

fn handleNcHitTest(
    hwnd: win.HWND,
    lparam: win.LPARAM,
) win.LRESULT {
    const screen_x =
        signedLowWord(lparam);

    const screen_y =
        signedHighWord(lparam);

    var window_rect: win.RECT = undefined;

    _ = win.GetWindowRect(
        hwnd,
        &window_rect,
    );

    const x =
        screen_x - window_rect.left;

    const y =
        screen_y - window_rect.top;

    const zone = hitZone(x, y);

    if (zone == .minimize or zone == .close) {
        return 1; // HTCLIENT
    }

    if (y >= 0 and y < TITLEBAR_HEIGHT) {
        return 2; // HTCAPTION
    }

    return 1; // HTCLIENT
}

// =====================================================================
// Window procedure
// =====================================================================

fn wndProc(
    hwnd: win.HWND,
    msg: win.UINT,
    wparam: win.WPARAM,
    lparam: win.LPARAM,
) callconv(.C) win.LRESULT {
    switch (msg) {
        // -------------------------------------------------------------
        // Paint
        // -------------------------------------------------------------

        win.WM_PAINT => {
            var ps: win.PAINTSTRUCT = undefined;

            const hdc =
                win.BeginPaint(
                    hwnd,
                    &ps,
                );

            if (hdc != null) {
                paintWindow(
                    hwnd,
                    hdc,
                );

                _ = win.EndPaint(
                    hwnd,
                    &ps,
                );
            }

            return 0;
        },

        // -------------------------------------------------------------
        // Avoid background erase flicker.
        // -------------------------------------------------------------

        win.WM_ERASEBKGND => {
            return 1;
        },

        // -------------------------------------------------------------
        // Resize
        // -------------------------------------------------------------

        win.WM_SIZE => {
            updateWindowRegion(hwnd);

            _ = win.InvalidateRect(
                hwnd,
                null,
                0,
            );

            return 0;
        },

        // -------------------------------------------------------------
        // Hover tracking — repaint whenever the hovered zone changes,
        // and ask Windows for a WM_MOUSELEAVE once the cursor exits.
        // -------------------------------------------------------------

        win.WM_MOUSEMOVE => {
            const x = signedLowWord(lparam);
            const y = signedHighWord(lparam);

            const zone = hitZone(x, y);

            if (zone != hover_zone) {
                hover_zone = zone;

                _ = win.InvalidateRect(
                    hwnd,
                    null,
                    0,
                );
            }

            if (!mouse_tracking) {
                var tme = std.mem.zeroes(win.TRACKMOUSEEVENT);
                tme.cbSize = @sizeOf(win.TRACKMOUSEEVENT);
                tme.dwFlags = win.TME_LEAVE;
                tme.hwndTrack = hwnd;

                _ = win.TrackMouseEvent(&tme);
                mouse_tracking = true;
            }

            return 0;
        },

        win.WM_MOUSELEAVE => {
            mouse_tracking = false;

            if (hover_zone != .none) {
                hover_zone = .none;

                _ = win.InvalidateRect(
                    hwnd,
                    null,
                    0,
                );
            }

            return 0;
        },

        // -------------------------------------------------------------
        // Show a hand cursor over anything clickable.
        // -------------------------------------------------------------

        win.WM_SETCURSOR => {
            const hit_result: u16 =
                @truncate(@as(usize, @bitCast(lparam)) & 0xFFFF);

            if (hit_result == 1) { // HTCLIENT
                const cursor_id: usize = switch (hover_zone) {
                    .minimize, .close, .toggle, .access_row, .card => IDC_HAND,
                    .none => IDC_ARROW,
                };

                _ = win.SetCursor(
                    LoadCursorW(null, cursor_id),
                );

                return 1;
            }

            return win.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        // -------------------------------------------------------------
        // Custom title-bar hit testing.
        // -------------------------------------------------------------

        win.WM_NCHITTEST => {
            return handleNcHitTest(
                hwnd,
                lparam,
            );
        },

        // -------------------------------------------------------------
        // Mouse clicks
        // -------------------------------------------------------------

        win.WM_LBUTTONUP => {
            const x =
                signedLowWord(lparam);

            const y =
                signedHighWord(lparam);

            switch (hitZone(x, y)) {
                .minimize => {
                    _ = win.ShowWindow(
                        hwnd,
                        win.SW_MINIMIZE,
                    );
                },

                .close => {
                    // Close the settings window, but keep Zigoclip
                    // running in the tray.
                    hideMainWindow(hwnd);
                },

                .toggle => {
                    setAutostartEnabled(
                        !isAutostartEnabled(),
                    );

                    _ = win.InvalidateRect(
                        hwnd,
                        null,
                        0,
                    );
                },

                .access_row => {
                    openAccessManagement();
                },

                .card => {
                    openGithub();
                },

                .none => {},
            }

            return 0;
        },

        // -------------------------------------------------------------
        // Window close
        // -------------------------------------------------------------
        //
        // Unlike Exit, clicking X merely hides the settings window.
        // The application remains in the system tray.
        //

        win.WM_CLOSE => {
            hideMainWindow(hwnd);
            return 0;
        },

        // -------------------------------------------------------------
        // Tray icon events
        // -------------------------------------------------------------

        WM_TRAYICON => {
            if (lparam == win.WM_LBUTTONUP) {
                showMainWindow();
                return 0;
            }

            if (lparam == win.WM_RBUTTONUP) {
                showTrayMenu(hwnd);
                return 0;
            }

            return 0;
        },

        // -------------------------------------------------------------
        // Tray menu commands
        // -------------------------------------------------------------

        win.WM_COMMAND => {
            const id: u16 =
                @truncate(wparam & 0xFFFF);

            switch (id) {
                ID_OPEN => {
                    showMainWindow();
                },

                ID_STARTUP_TOGGLE => {
                    setAutostartEnabled(
                        !isAutostartEnabled(),
                    );

                    _ = win.InvalidateRect(
                        hwnd,
                        null,
                        0,
                    );
                },

                ID_ACCESS_MANAGEMENT => {
                    openAccessManagement();
                },

                ID_GITHUB => {
                    openGithub();
                },

                ID_EXIT => {
                    quit_requested = true;

                    _ = win.DestroyWindow(
                        hwnd,
                    );
                },

                else => {},
            }

            return 0;
        },

        // -------------------------------------------------------------
        // Destroy
        // -------------------------------------------------------------

        win.WM_DESTROY => {
            _ = win.Shell_NotifyIconW(
                win.NIM_DELETE,
                &tray_icon_data,
            );

            // The important part:
            //
            // Closing the job handle with
            // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            // kills zigoclip.exe and its clipboard.exe child.
            //
            // We intentionally do NOT do this when merely hiding the
            // settings window. This only happens during real Exit.

            if (job_object) |job| {
                _ = win.CloseHandle(job);
                job_object = null;
            }

            if (child_process) |proc| {
                _ = win.CloseHandle(proc);
                child_process = null;
            }

            if (github_icon) |icon| {
                _ = win.DestroyIcon(icon);
                github_icon = null;
            }

            win.PostQuitMessage(0);

            return 0;
        },

        else => {},
    }

    return win.DefWindowProcW(
        hwnd,
        msg,
        wparam,
        lparam,
    );
}

// =====================================================================
// Main
// =====================================================================

pub fn main() !void {
    // ---------------------------------------------------------------
    // Locate our executable directory.
    // ---------------------------------------------------------------

    var exe_path_buf:
        [win.MAX_PATH]u16 = undefined;

    const exe_dir =
        computeExeDir(
            &exe_path_buf,
        );

    // ---------------------------------------------------------------
    // Load bundled assets.
    // ---------------------------------------------------------------

    loadGithubIcon();

    // ---------------------------------------------------------------
    // Create Job Object BEFORE spawning the agent.
    // ---------------------------------------------------------------

    job_object =
        createJobObject();

    if (job_object == null) {
        return error.CreateJobObjectFailed;
    }

    // ---------------------------------------------------------------
    // Start zigoclip.exe.
    // ---------------------------------------------------------------

    if (spawnAgent(exe_dir)) |handle| {
        child_process = handle;
    } else |err| {
        // GUI subsystem means there is no visible console.
        // The tray window can still start.
        std.debug.print(
            "Failed to start zigoclip agent: {}\n",
            .{err},
        );
    }

    // ---------------------------------------------------------------
    // Register window class.
    // ---------------------------------------------------------------

    const class_name =
        wide("ZigoclipTrayWindow");

    var wc =
        std.mem.zeroes(
            win.WNDCLASSEXW,
        );

    wc.cbSize =
        @sizeOf(win.WNDCLASSEXW);

    wc.style =
        win.CS_HREDRAW |
        win.CS_VREDRAW;

    wc.lpfnWndProc =
        wndProc;

    wc.hInstance =
        win.GetModuleHandleW(null);

    wc.hIcon =
        LoadIconW(
            null,
            IDI_APPLICATION,
        );

    wc.hCursor =
        LoadCursorW(null, IDC_ARROW);

    wc.hbrBackground =
        null;

    wc.lpszClassName =
        class_name;

    if (
        win.RegisterClassExW(
            &wc,
        ) == 0
    ) {
        if (job_object) |job| {
            _ = win.CloseHandle(job);
            job_object = null;
        }

        if (child_process) |proc| {
            _ = win.CloseHandle(proc);
            child_process = null;
        }

        return error.RegisterClassFailed;
    }

    // ---------------------------------------------------------------
    // Center window on the primary screen.
    // ---------------------------------------------------------------

    const screen_width =
        win.GetSystemMetrics(
            win.SM_CXSCREEN,
        );

    const screen_height =
        win.GetSystemMetrics(
            win.SM_CYSCREEN,
        );

    const window_x =
        @divTrunc(
            screen_width - WINDOW_WIDTH,
            2,
        );

    const window_y =
        @divTrunc(
            screen_height - WINDOW_HEIGHT,
            2,
        );

    // ---------------------------------------------------------------
    // Create custom-framed window.
    // ---------------------------------------------------------------
    //
    // WS_POPUP removes the standard Windows title bar.
    // We paint our own title bar to match the reference UI.

    const hwnd =
        win.CreateWindowExW(
            win.WS_EX_APPWINDOW,
            class_name,
            wide("Zigoclip"),
            win.WS_POPUP,
            window_x,
            window_y,
            WINDOW_WIDTH,
            WINDOW_HEIGHT,
            null,
            null,
            wc.hInstance,
            null,
        );

    if (hwnd == null) {
        if (job_object) |job| {
            _ = win.CloseHandle(job);
            job_object = null;
        }

        if (child_process) |proc| {
            _ = win.CloseHandle(proc);
            child_process = null;
        }

        return error.CreateWindowFailed;
    }

    main_hwnd = hwnd;

    // Give the window rounded corners.
    updateWindowRegion(hwnd);

    // ---------------------------------------------------------------
    // Add tray icon.
    // ---------------------------------------------------------------

    addTrayIcon(hwnd);

    // ---------------------------------------------------------------
    // Show the actual settings UI.
    // ---------------------------------------------------------------

    _ = win.ShowWindow(
        hwnd,
        win.SW_SHOW,
    );

    _ = win.UpdateWindow(
        hwnd,
    );

    // ---------------------------------------------------------------
    // Message loop.
    // ---------------------------------------------------------------

    var msg: win.MSG = undefined;

    while (
        win.GetMessageW(
            &msg,
            null,
            0,
            0,
        ) > 0
    ) {
        _ = win.TranslateMessage(
            &msg,
        );

        _ = win.DispatchMessageW(
            &msg,
        );
    }

    _ = quit_requested;
}