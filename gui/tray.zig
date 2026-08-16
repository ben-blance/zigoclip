// Zigoclip tray + settings window
//
// Zig 0.13 / MinGW / native Win32.
//
// UI target:
//   - dark desktop-style settings window
//   - blue title bar
//   - green Zigoclip accent
//   - large "Launch on Windows startup" toggle
//   - "Manage access" link
//   - GitHub source-code card
//
// Runtime responsibilities:
//   - launch zigoclip.exe
//   - supervise zigoclip.exe -> clipboard.exe with a Job Object
//   - kill the whole job when Exit is chosen
//   - provide a system tray icon
//   - provide Start with Windows
//   - open Access Management
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

const WINDOW_WIDTH = 1240;
const WINDOW_HEIGHT = 700;
const TITLEBAR_HEIGHT = 64;

// Custom title-bar button rectangles.
const TITLE_MIN_LEFT = 1035;
const TITLE_MIN_RIGHT = 1090;

const TITLE_MAX_LEFT = 1090;
const TITLE_MAX_RIGHT = 1145;

const TITLE_CLOSE_LEFT = 1145;
const TITLE_CLOSE_RIGHT = 1240;

// Main UI rectangles.
const TOGGLE_LEFT = 985;
const TOGGLE_TOP = 142;
const TOGGLE_RIGHT = 1150;
const TOGGLE_BOTTOM = 194;

const ACCESS_LEFT = 70;
const ACCESS_TOP = 270;
const ACCESS_RIGHT = 400;
const ACCESS_BOTTOM = 315;

const CARD_LEFT = 70;
const CARD_TOP = 350;
const CARD_RIGHT = 1170;
const CARD_BOTTOM = 454;

// =====================================================================
// Colors
// =====================================================================
//
// COLORREF is encoded as 0x00BBGGRR.
//

fn rgb(r: u8, g: u8, b: u8) win.DWORD {
    return @as(win.DWORD, r) |
        (@as(win.DWORD, g) << 8) |
        (@as(win.DWORD, b) << 16);
}

const COLOR_BG = rgb(12, 18, 21);
const COLOR_BG_2 = rgb(15, 23, 26);
const COLOR_BLUE = rgb(45, 105, 201);
const COLOR_BLUE_DARK = rgb(35, 82, 160);
const COLOR_GREEN = rgb(135, 210, 77);
const COLOR_GREEN_DARK = rgb(105, 170, 59);
const COLOR_WHITE = rgb(245, 247, 249);
const COLOR_TEXT = rgb(235, 239, 242);
const COLOR_MUTED = rgb(145, 157, 164);
const COLOR_CARD = rgb(20, 28, 31);
const COLOR_CARD_HOVER = rgb(25, 35, 39);
const COLOR_BORDER = rgb(59, 67, 70);
const COLOR_OFF = rgb(70, 79, 83);
const COLOR_KNOB = rgb(248, 249, 250);

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

const HKEY_CURRENT_USER: usize = 0x80000001;
const IDI_APPLICATION: usize = 32512;

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

// =====================================================================
// Global state
// =====================================================================

var tray_icon_data: win.NOTIFYICONDATAW = undefined;

var child_process: ?win.HANDLE = null;
var job_object: ?win.HANDLE = null;

var main_hwnd: ?win.HWND = null;

var quit_requested = false;

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

    return buf[0..cut];
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
    const c = COLOR_GREEN;

    // Dashed rounded-square approximation.
    //
    // Top.
    fillRoundRect(hdc, x + 5, y, x + 18, y + 4, 2, c);
    fillRoundRect(hdc, x + 24, y, x + 37, y + 4, 2, c);

    // Bottom.
    fillRoundRect(hdc, x + 5, y + 36, x + 18, y + 40, 2, c);
    fillRoundRect(hdc, x + 24, y + 36, x + 37, y + 40, 2, c);

    // Left.
    fillRoundRect(hdc, x, y + 5, x + 4, y + 17, 2, c);
    fillRoundRect(hdc, x, y + 23, x + 4, y + 35, 2, c);

    // Right.
    fillRoundRect(hdc, x + 38, y + 5, x + 42, y + 17, 2, c);
    fillRoundRect(hdc, x + 38, y + 23, x + 42, y + 35, 2, c);
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
    // Entire background / border
    // ---------------------------------------------------------------

    fillRect(
        hdc,
        0,
        0,
        width,
        height,
        COLOR_BLUE,
    );

    // Inner body.
    fillRect(
        hdc,
        2,
        TITLEBAR_HEIGHT,
        width - 2,
        height - 2,
        COLOR_BG,
    );

    // ---------------------------------------------------------------
    // Title bar
    // ---------------------------------------------------------------

    fillRect(
        hdc,
        2,
        2,
        width - 2,
        TITLEBAR_HEIGHT,
        COLOR_BLUE,
    );

    drawLogo(
        hdc,
        30,
        12,
    );

    drawText(
        hdc,
        wide("Zigoclip"),
        92,
        17,
        28,
        400,
        COLOR_WHITE,
    );

    // ---------------------------------------------------------------
    // Window controls
    // ---------------------------------------------------------------

    // Minimize.
    fillRect(
        hdc,
        TITLE_MIN_LEFT + 18,
        31,
        TITLE_MIN_LEFT + 42,
        33,
        COLOR_WHITE,
    );

    // Maximize / restore.
    if (win.IsZoomed(hwnd) != 0) {
        // Restore icon.
        fillRect(
            hdc,
            TITLE_MAX_LEFT + 17,
            24,
            TITLE_MAX_LEFT + 37,
            26,
            COLOR_WHITE,
        );

        fillRect(
            hdc,
            TITLE_MAX_LEFT + 17,
            26,
            TITLE_MAX_LEFT + 19,
            42,
            COLOR_WHITE,
        );

        fillRect(
            hdc,
            TITLE_MAX_LEFT + 35,
            26,
            TITLE_MAX_LEFT + 37,
            42,
            COLOR_WHITE,
        );

        fillRect(
            hdc,
            TITLE_MAX_LEFT + 19,
            40,
            TITLE_MAX_LEFT + 35,
            42,
            COLOR_WHITE,
        );
    } else {
        fillRect(
            hdc,
            TITLE_MAX_LEFT + 17,
            23,
            TITLE_MAX_LEFT + 38,
            25,
            COLOR_WHITE,
        );

        fillRect(
            hdc,
            TITLE_MAX_LEFT + 17,
            23,
            TITLE_MAX_LEFT + 19,
            42,
            COLOR_WHITE,
        );

        fillRect(
            hdc,
            TITLE_MAX_LEFT + 36,
            23,
            TITLE_MAX_LEFT + 38,
            42,
            COLOR_WHITE,
        );

        fillRect(
            hdc,
            TITLE_MAX_LEFT + 17,
            40,
            TITLE_MAX_LEFT + 38,
            42,
            COLOR_WHITE,
        );
    }

    // Close X.
    fillRect(
        hdc,
        TITLE_CLOSE_LEFT + 19,
        20,
        TITLE_CLOSE_LEFT + 22,
        44,
        COLOR_WHITE,
    );

    fillRect(
        hdc,
        TITLE_CLOSE_LEFT + 38,
        20,
        TITLE_CLOSE_LEFT + 41,
        44,
        COLOR_WHITE,
    );

    // ---------------------------------------------------------------
    // Main heading
    // ---------------------------------------------------------------

    drawText(
        hdc,
        wide("Launch on Windows startup"),
        72,
        138,
        34,
        700,
        COLOR_WHITE,
    );

    // ---------------------------------------------------------------
    // Startup toggle
    // ---------------------------------------------------------------

    const startup_enabled =
        isAutostartEnabled();

    const toggle_color =
        if (startup_enabled)
            COLOR_GREEN
        else
            COLOR_OFF;

    fillRoundRect(
        hdc,
        TOGGLE_LEFT,
        TOGGLE_TOP,
        TOGGLE_RIGHT,
        TOGGLE_BOTTOM,
        28,
        toggle_color,
    );

    // Knob.
    if (startup_enabled) {
        fillEllipse(
            hdc,
            TOGGLE_RIGHT - 50,
            TOGGLE_TOP + 5,
            TOGGLE_RIGHT - 5,
            TOGGLE_BOTTOM - 5,
            COLOR_KNOB,
        );
    } else {
        fillEllipse(
            hdc,
            TOGGLE_LEFT + 5,
            TOGGLE_TOP + 5,
            TOGGLE_LEFT + 50,
            TOGGLE_BOTTOM - 5,
            COLOR_KNOB,
        );
    }

    // ---------------------------------------------------------------
    // Manage access
    // ---------------------------------------------------------------

    drawText(
        hdc,
        wide("Manage access"),
        72,
        268,
        27,
        500,
        COLOR_GREEN,
    );

    // Small arrow.
    drawText(
        hdc,
        wide(">"),
        280,
        270,
        24,
        600,
        COLOR_GREEN,
    );

    // ---------------------------------------------------------------
    // GitHub/source card
    // ---------------------------------------------------------------

    const card_color =
        COLOR_CARD;

    fillRoundRect(
        hdc,
        CARD_LEFT,
        CARD_TOP,
        CARD_RIGHT,
        CARD_BOTTOM,
        16,
        card_color,
    );

    frameRoundRect(
        hdc,
        CARD_LEFT,
        CARD_TOP,
        CARD_RIGHT,
        CARD_BOTTOM,
        16,
        COLOR_BORDER,
    );

    // GitHub circle.
    fillEllipse(
        hdc,
        CARD_LEFT + 28,
        CARD_TOP + 24,
        CARD_LEFT + 82,
        CARD_TOP + 78,
        COLOR_WHITE,
    );

    drawText(
        hdc,
        wide("GH"),
        CARD_LEFT + 39,
        CARD_TOP + 37,
        15,
        700,
        COLOR_BG,
    );

    drawText(
        hdc,
        wide("Check out the source code on GitHub"),
        CARD_LEFT + 122,
        CARD_TOP + 32,
        28,
        400,
        COLOR_GREEN,
    );

    // ---------------------------------------------------------------
    // Small footer
    // ---------------------------------------------------------------

    drawText(
        hdc,
        wide("Zigoclip"),
        72,
        height - 45,
        14,
        500,
        COLOR_MUTED,
    );
}

// =====================================================================
// Rounded window region
// =====================================================================

fn updateWindowRegion(hwnd: win.HWND) void {
    if (win.IsZoomed(hwnd) != 0) {
        // No rounded corners when maximized.
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
            24,
            24,
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

    if (y >= 0 and
        y < TITLEBAR_HEIGHT)
    {
        if (
            pointInRect(
                x,
                y,
                TITLE_MIN_LEFT,
                0,
                TITLE_MIN_RIGHT,
                TITLEBAR_HEIGHT,
            ) or
            pointInRect(
                x,
                y,
                TITLE_MAX_LEFT,
                0,
                TITLE_MAX_RIGHT,
                TITLEBAR_HEIGHT,
            ) or
            pointInRect(
                x,
                y,
                TITLE_CLOSE_LEFT,
                0,
                TITLE_CLOSE_RIGHT,
                TITLEBAR_HEIGHT,
            )
        ) {
            return 1; // HTCLIENT
        }

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

            // ---------------------------------------------------------
            // Title bar buttons
            // ---------------------------------------------------------

            if (
                pointInRect(
                    x,
                    y,
                    TITLE_MIN_LEFT,
                    0,
                    TITLE_MIN_RIGHT,
                    TITLEBAR_HEIGHT,
                )
            ) {
                _ = win.ShowWindow(
                    hwnd,
                    win.SW_MINIMIZE,
                );

                return 0;
            }

            if (
                pointInRect(
                    x,
                    y,
                    TITLE_MAX_LEFT,
                    0,
                    TITLE_MAX_RIGHT,
                    TITLEBAR_HEIGHT,
                )
            ) {
                if (win.IsZoomed(hwnd) != 0) {
                    _ = win.ShowWindow(
                        hwnd,
                        win.SW_RESTORE,
                    );
                } else {
                    _ = win.ShowWindow(
                        hwnd,
                        win.SW_MAXIMIZE,
                    );
                }

                return 0;
            }

            if (
                pointInRect(
                    x,
                    y,
                    TITLE_CLOSE_LEFT,
                    0,
                    TITLE_CLOSE_RIGHT,
                    TITLEBAR_HEIGHT,
                )
            ) {
                // Close the settings window, but keep Zigoclip
                // running in the tray.
                hideMainWindow(hwnd);

                return 0;
            }

            // ---------------------------------------------------------
            // Startup toggle
            // ---------------------------------------------------------

            if (
                pointInRect(
                    x,
                    y,
                    TOGGLE_LEFT - 10,
                    TOGGLE_TOP - 10,
                    TOGGLE_RIGHT + 10,
                    TOGGLE_BOTTOM + 10,
                )
            ) {
                setAutostartEnabled(
                    !isAutostartEnabled(),
                );

                _ = win.InvalidateRect(
                    hwnd,
                    null,
                    0,
                );

                return 0;
            }

            // ---------------------------------------------------------
            // Manage access
            // ---------------------------------------------------------

            if (
                pointInRect(
                    x,
                    y,
                    ACCESS_LEFT,
                    ACCESS_TOP - 8,
                    ACCESS_RIGHT,
                    ACCESS_BOTTOM + 8,
                )
            ) {
                openAccessManagement();

                return 0;
            }

            // ---------------------------------------------------------
            // GitHub card
            // ---------------------------------------------------------

            if (
                pointInRect(
                    x,
                    y,
                    CARD_LEFT,
                    CARD_TOP,
                    CARD_RIGHT,
                    CARD_BOTTOM,
                )
            ) {
                openGithub();

                return 0;
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
        null;

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