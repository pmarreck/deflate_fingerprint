//! ZIP-family container classification for corpus probes.
//!
//! This keeps archive-extension policy tested and producer-agnostic: the core
//! DEFLATE engine remains RFC1951-only, while probes use this to find containers
//! that may hold method=8 raw-DEFLATE entries.

const std = @import("std");

const ZIP_FAMILY_EXTENSIONS = [_][]const u8{
    ".zip",
    ".docx",
    ".xlsx",
    ".pptx",
    ".jar",
    ".war",
    ".ear",
    ".apk",
    ".ipa",
    ".whl",
    ".xpi",
    ".crx",
    ".vsix",
    ".odt",
    ".ods",
    ".odp",
    ".epub",
    ".cbz",
};

/// Classify ZIP-family filenames by extension for corpus extraction. This is a
/// container-discovery helper only; RFC1951 reproduction stays separate.
pub fn isZipFamilyFilename(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "._")) return false;
    for (ZIP_FAMILY_EXTENSIONS) |ext| {
        if (name.len < ext.len) continue;
        const tail = name[name.len - ext.len ..];
        if (std.ascii.eqlIgnoreCase(tail, ext)) return true;
    }
    return false;
}

test "isZipFamilyFilename classifies supported ZIP-family extensions as a set" {
    const yes = [_][]const u8{
        "a.zip",
        "a.docx",
        "a.xlsx",
        "a.pptx",
        "a.jar",
        "a.war",
        "a.ear",
        "a.apk",
        "a.ipa",
        "a.whl",
        "a.xpi",
        "a.crx",
        "a.vsix",
        "a.odt",
        "a.ods",
        "a.odp",
        "a.epub",
        "a.cbz",
        "A.XLSX",
        "plugin.XPI",
    };
    for (yes) |name| {
        try std.testing.expect(isZipFamilyFilename(name));
    }
}

test "isZipFamilyFilename rejects sidecars and non-ZIP-family names as a set" {
    const no = [_][]const u8{
        "._a.zip",
        "a.pdf",
        "a.png",
        "a.gz",
        "zip",
        "archive.zip.tmp",
        "xlsx",
    };
    for (no) |name| {
        try std.testing.expect(!isZipFamilyFilename(name));
    }
}
