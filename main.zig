// File: src/main.zig
const std = @import("std");
const c = @cImport({
    @cInclude("libevtx.h");
    @cInclude("libxml/parser.h");
    @cInclude("libxml/tree.h");
});

const OutputFormat = enum {
    csv,
    json,
    jsonl,
    xml,
};

// Custom error types
const ZigZapError = error{
    FileOpenError,
    LibEvtxError,
    LibXmlError,
    OutputError,
    InvalidArguments,
    InvalidFormat,
};

// Main function
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 7 or !std.mem.eql(u8, args[1], "--input") or !std.mem.eql(u8, args[3], "--output") or !std.mem.eql(u8, args[5], "--format")) {
        std.debug.print("Usage: zigzap --input <file.evtx> --output <file> --format <csv|json|jsonl|xml>\n", .{});
        return ZigZapError.InvalidArguments;
    }

    const input_file = args[2];
    const output_file = args[4];
    const format_str = args[6];
    const format = std.meta.stringToEnum(OutputFormat, format_str) orelse return ZigZapError.InvalidFormat;

    // Open output file
    const out_file = try std.fs.cwd().createFile(output_file, .{});
    defer out_file.close();
    const out_writer = out_file.writer();

    // Initialize libevtx
    var evtx_file: ?*c.libevtx_file_t = null;
    var evtx_error: ?*c.libevtx_error_t = null;
    if (c.libevtx_file_initialize(&evtx_file, &evtx_error) != 1) {
        printEvtxError("Failed to initialize libevtx", evtx_error);
        return ZigZapError.LibEvtxError;
    }
    defer _ = c.libevtx_file_free(&evtx_file, &evtx_error);

    // Open .evtx file
    if (c.libevtx_file_open(evtx_file, input_file.ptr, c.LIBEVTX_OPEN_READ, &evtx_error) != 1) {
        printEvtxError("Failed to open .evtx file", evtx_error);
        return ZigZapError.FileOpenError;
    }

    // Get number of records
    var num_records: i32 = 0;
    if (c.libevtx_file_get_number_of_records(evtx_file, &num_records, &evtx_error) != 1) {
        printEvtxError("Failed to get number of records", evtx_error);
        return ZigZapError.LibEvtxError;
    }

    // Initialize output based on format
    switch (format) {
        .xml => try out_writer.writeAll("<Events>\n"),
        .json => try out_writer.writeAll("["),
        .csv => try out_writer.writeAll("TimeCreated,EventID,Level\n"),
        .jsonl => {},
    }

    // Process each record
    var first_record = true;
    for (0..@intCast(num_records)) |i| {
        var record: ?*c.libevtx_record_t = null;
        if (c.libevtx_file_get_record(evtx_file, @intCast(i), &record, &evtx_error) != 1) {
            printEvtxError("Failed to get record", evtx_error);
            continue;
        }
        defer _ = c.libevtx_record_free(&record, &evtx_error);

        // Handle output format
        switch (format) {
            .xml => try handleXml(record, out_writer, &evtx_error),
            .json => {
                if (!first_record) try out_writer.writeAll(",");
                try handleJson(record, out_writer, allocator, &evtx_error);
                first_record = false;
            },
            .jsonl => try handleJson(record, out_writer, allocator, &evtx_error),
            .csv => try handleCsv(record, out_writer, &evtx_error),
        }
    }

    // Finalize output
    switch (format) {
        .xml => try out_writer.writeAll("\n</Events>"),
        .json => try out_writer.writeAll("]"),
        .csv, .jsonl => {},
    }
}

// Helper to print libevtx errors
fn printEvtxError(comptime msg: []const u8, evtx_error: ?*c.libevtx_error_t) void {
    if (evtx_error) |err| {
        var error_desc: [1024]u8 = undefined;
        const desc_size = c.libevtx_error_sprint(err, &error_desc[0], error_desc.len);
        if (desc_size > 0) {
            std.debug.print("{s}: {s}\n", .{ msg, error_desc[0..@min(@intCast(desc_size), error_desc.len)] });
        } else {
            std.debug.print("{s}: Unknown libevtx error\n", .{msg});
        }
    } else {
        std.debug.print("{s}: Unknown libevtx error\n", .{msg});
    }
}

// XML Output
fn handleXml(record: ?*c.libevtx_record_t, writer: anytype, evtx_error: ?*?*c.libevtx_error_t) !void {
    var xml_string: ?[*:0]u8 = null;
    var xml_string_size: i32 = 0;

    if (c.libevtx_record_get_utf8_xml_string(record, &xml_string, &xml_string_size, evtx_error) != 1) {
        return ZigZapError.LibEvtxError;
    }

    try writer.writeAll(std.mem.sliceTo(xml_string, 0));
    try writer.writeAll("\n");
}

// CSV Output
fn handleCsv(record: ?*c.libevtx_record_t, writer: anytype, evtx_error: ?*?*c.libevtx_error_t) !void {
    var time_created: ?[*:0]u8 = null;
    var time_created_size: i32 = 0;
    var event_id: i32 = 0;
    var level: ?[*:0]u8 = null;
    var level_size: i32 = 0;

    _ = c.libevtx_record_get_utf8_time_created(record, &time_created, &time_created_size, evtx_error);
    _ = c.libevtx_record_get_event_identifier(record, &event_id, evtx_error);
    _ = c.libevtx_record_get_utf8_level(record, &level, &level_size, evtx_error);

    try writer.print("\"{s}\",\"{d}\",\"{s}\"\n", .{
        if (time_created != null) std.mem.sliceTo(time_created, 0) else "",
        event_id,
        if (level != null) std.mem.sliceTo(level, 0) else "",
    });
}

// JSON Output: Parse XML and convert to structured JSON
fn handleJson(record: ?*c.libevtx_record_t, writer: anytype, allocator: std.mem.Allocator, evtx_error: ?*?*c.libevtx_error_t) !void {
    var xml_string: ?[*:0]u8 = null;
    var xml_string_size: i32 = 0;

    if (c.libevtx_record_get_utf8_xml_string(record, &xml_string, &xml_string_size, evtx_error) != 1) {
        return ZigZapError.LibEvtxError;
    }

    // Parse XML with libxml2
    const xml_doc = c.xmlParseDoc(xml_string) orelse return ZigZapError.LibXmlError;
    defer c.xmlFreeDoc(xml_doc);

    const root = c.xmlDocGetRootElement(xml_doc) orelse return ZigZapError.LibXmlError;

    // Build JSON by traversing the XML tree
    var json_buffer = std.ArrayList(u8).init(allocator);
    defer json_buffer.deinit();
    const json_writer = json_buffer.writer();

    try json_writer.writeAll("{");
    try xmlToJson(root, json_writer, allocator);
    try json_writer.writeAll("}");

    try writer.writeAll(json_buffer.items);
    if (@intFromEnum(writer.context) == @intFromEnum(OutputFormat.jsonl)) try writer.writeAll("\n");
}

// Helper to convert XML to JSON
fn xmlToJson(node: *c.xmlNode, writer: anytype, allocator: std.mem.Allocator) !void {
    var first = true;
    var child = node.children;
    while (child != null) : (child = child.next) {
        if (child.type != c.XML_ELEMENT_NODE) continue;

        if (!first) try writer.writeAll(",");
        first = false;

        const name = std.mem.sliceTo(child.name, 0);
        try writer.print("\"{s}\":", .{name});

        // Check if the node has children (nested object) or content (value)
        if (child.children != null and child.children.type == c.XML_ELEMENT_NODE) {
            try writer.writeAll("{");
            try xmlToJson(child, writer, allocator);
            try writer.writeAll("}");
        } else {
            const content = c.xmlNodeGetContent(child) orelse "";
            const content_str = std.mem.sliceTo(content, 0);
            try writer.print("\"{s}\"", .{content_str});
            if (content.len > 0) c.xmlFree(content);
        }
    }
}
