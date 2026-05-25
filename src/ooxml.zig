//! OOXML metadata helpers for corpus attribution.
//!
//! These helpers intentionally parse only the small producer fields needed to
//! cluster compression behavior by observed Office/LibreOffice version.

const std = @import("std");

pub const AppMetadata = struct {
    application: ?[]const u8 = null,
    app_version: ?[]const u8 = null,
};

fn tagText(xml: []const u8, tag: []const u8) ?[]const u8 {
    var open_buf: [64]u8 = undefined;
    var close_buf: [64]u8 = undefined;
    if (tag.len + 2 > open_buf.len or tag.len + 3 > close_buf.len) return null;

    const open = std.fmt.bufPrint(open_buf[0..], "<{s}>", .{tag}) catch unreachable;
    const close = std.fmt.bufPrint(close_buf[0..], "</{s}>", .{tag}) catch unreachable;

    const start = std.mem.indexOf(u8, xml, open) orelse return null;
    const text_start = start + open.len;
    const text_end_rel = std.mem.indexOf(u8, xml[text_start..], close) orelse return null;
    return xml[text_start .. text_start + text_end_rel];
}

/// Parse `docProps/app.xml` producer fields used for Office/OOXML clustering.
/// Returned slices point into `xml`; callers own the XML buffer lifetime.
pub fn parseAppMetadata(xml: []const u8) AppMetadata {
    return .{
        .application = tagText(xml, "Application"),
        .app_version = tagText(xml, "AppVersion"),
    };
}

/// Classify OOXML worksheet XML entries for Excel-family DEFLATE probes.
/// This keeps worksheet-specific hypotheses away from workbook/shared XML.
pub fn isWorksheetPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "xl/worksheets/") and std.mem.endsWith(u8, path, ".xml");
}

const testing = std.testing;

test "parseAppMetadata extracts Microsoft Excel producer fields" {
    const xml =
        \\<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">
        \\<Application>Microsoft Excel</Application>
        \\<AppVersion>16.0300</AppVersion>
        \\</Properties>
    ;
    const meta = parseAppMetadata(xml);
    try testing.expectEqualStrings("Microsoft Excel", meta.application.?);
    try testing.expectEqualStrings("16.0300", meta.app_version.?);
}

test "parseAppMetadata tolerates missing fields" {
    const meta = parseAppMetadata("<Properties><Application>LibreOffice</Application></Properties>");
    try testing.expectEqualStrings("LibreOffice", meta.application.?);
    try testing.expectEqual(null, meta.app_version);
}

test "isWorksheetPath classifies only OOXML worksheet XML entries" {
    const positives = [_][]const u8{
        "xl/worksheets/sheet1.xml",
        "xl/worksheets/sheet42.xml",
        "xl/worksheets/_rels/sheet1.xml",
    };
    const negatives = [_][]const u8{
        "xl/workbook.xml",
        "xl/sharedStrings.xml",
        "xl/worksheets/sheet1.xml.rels",
        "word/worksheets/sheet1.xml",
        "xl/worksheets/sheet1.bin",
    };

    for (positives) |path| try testing.expect(isWorksheetPath(path));
    for (negatives) |path| try testing.expect(!isWorksheetPath(path));
}
