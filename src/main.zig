const std = @import("std");

const Vec2 = struct {
    row: usize,
    col: usize,
};

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

const BLACK = Rgb{ .r = 0, .g = 0, .b = 0 };
const WHITE = Rgb{ .r = 255, .g = 255, .b = 255 };
const RED = Rgb{ .r = 255, .g = 0, .b = 0 };
const GREEN = Rgb{ .r = 0, .g = 255, .b = 0 };
const BLUE = Rgb{ .r = 0, .g = 0, .b = 255 };

const Screen = struct {
    size: Vec2,
    io: std.Io,
    writer_buffer: [4096]u8,
    file_writer: std.Io.File.Writer,
    reader_buffer: [4096]u8,
    file_reader: std.Io.File.Reader,
    orig_termios: std.posix.termios,
    pub fn init(io: std.Io) !Screen {
        // 1. Enable Raw Mode for input handling
        const orig_termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = orig_termios;
        // Disable echo (don't print typed keys automatically) and canonical mode (read byte-by-byte)
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        // Disable Ctrl+C / Ctrl+Z signals so you can capture them as shortcuts instead
        raw.lflag.ISIG = false;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
        const stdout_file = std.Io.File.stdout();
        const stdin_file = std.Io.File.stdin();
        const size = try getTerminalSizePosix(stdout_file);
        var screen: Screen = .{
            .size = size,
            .io = io,
            .reader_buffer = undefined,
            .writer_buffer = undefined,
            .file_writer = undefined,
            .file_reader = undefined,
            .orig_termios = orig_termios,
        };
        screen.file_writer = stdout_file.writerStreaming(io, &screen.writer_buffer);
        screen.file_reader = stdin_file.readerStreaming(io, &screen.reader_buffer);
        const out = screen.writer();
        try out.print("\x1b[?1049h", .{}); // alternative screen buffer
        try out.print("\x1b[?25l", .{}); // hide cursor
        try out.print("\x1b[?7l", .{}); // disable line wrapping
        try screen.flush();
        return screen;
    }
    pub fn deinit(self: *Screen) void {
        const out = self.writer();
        out.print("\x1b[?7h", .{}) catch {}; // re-enable line wrapping
        out.print("\x1b[?25h", .{}) catch {}; // show cursor
        out.print("\x1b[?1049l", .{}) catch {}; // exit alternative screen buffer
        self.file_writer.interface.flush() catch {};
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.orig_termios) catch {};
    }
    pub fn writer(self: *Screen) *std.Io.Writer {
        return &self.file_writer.interface;
    }
    pub fn print(self: *Screen, comptime fmt: []const u8, args: anytype) !void {
        const interface = &self.file_writer.interface;
        try interface.print(fmt, args);
    }
    pub fn write(self: *Screen, s: []const u8) !void {
        const interface = &self.file_writer.interface;
        try interface.print("{s}", .{s});
    }
    pub fn flush(self: *Screen) !void {
        try self.writer().flush();
    }
    pub fn putCharRgb(
        self: *Screen,
        position: Vec2,
        ch: u8,
        fg: Rgb,
        bg: Rgb,
    ) !void {
        try self.print(
            "\x1b[{d};{d}H\x1b[38;2;{d};{d};{d}m\x1b[48;2;{d};{d};{d}m{c}",
            .{ position.row + 1, position.col + 1, fg.r, fg.g, fg.b, bg.r, bg.g, bg.b, ch },
        );
    }
};

fn getTerminalSizePosix(out_file: std.Io.File) !Vec2 {
    var winsize: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const err = std.posix.system.ioctl(
        out_file.handle,
        std.posix.T.IOCGWINSZ,
        @intFromPtr(&winsize),
    );
    if (std.posix.errno(err) != .SUCCESS) {
        return error.TerminalSizeUnavailable;
    }
    return Vec2{
        .row = winsize.row,
        .col = winsize.col,
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var screen = try Screen.init(io);
    defer screen.deinit();
    var args_it = init.minimal.args.iterate();
    _ = args_it.next(); // skip the executable name
    const optional_file_path = args_it.next();
    var cursor = Vec2{ .row = 0, .col = 0 };
    if (optional_file_path) |file_path| {
        const max_bytes: std.Io.Limit = .limited(10 * 1024 * 1024);
        const file_contents = try std.Io.Dir.cwd().readFileAlloc(
            io,
            file_path,
            gpa,
            max_bytes,
        );
        defer gpa.free(file_contents);
        while (true) {
            var file_contents_cursor: usize = 0;
            for (0..screen.size.row) |row_idx| {
                var line_printed = false;
                for (0..screen.size.col) |col_idx| {
                    const loc = Vec2{ .row = row_idx, .col = col_idx };
                    if (file_contents_cursor >= file_contents.len) {
                        line_printed = true;
                    }
                    const ch: u8 = if (!line_printed) blk: {
                        const char = file_contents[file_contents_cursor];
                        if (char == '\n') {
                            line_printed = true;
                            file_contents_cursor += 1;
                            break :blk ' ';
                        } else {
                            file_contents_cursor += 1;
                            break :blk char;
                        }
                    } else ' ';
                    if (std.meta.eql(loc, cursor)) {
                        try screen.putCharRgb(loc, ch, BLACK, WHITE);
                    } else {
                        try screen.putCharRgb(loc, ch, WHITE, BLACK);
                    }
                }
            }
            try screen.flush();
            const char = try screen.file_reader.interface.takeByte();
            switch (char) {
                'q' => return,
                'h' => cursor.col = @max(cursor.col -| 1, 0),
                'j' => cursor.row = @min(cursor.row + 1, screen.size.row - 1),
                'k' => cursor.row = @max(cursor.row -| 1, 0),
                'l' => cursor.col = @min(cursor.col + 1, screen.size.col - 1),
                '^' => cursor.col = 0,
                '$' => cursor.col = screen.size.col - 1,
                'G' => cursor.row = screen.size.row - 1,
                else => {},
            }
        }
    } else {
        std.debug.print("You must pass a file!\n", .{});
    }
}
