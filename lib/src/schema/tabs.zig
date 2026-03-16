const std = @import("std");
const xlsx = @import("../xlsx.zig");
const diagnostic = @import("../diagnostic.zig");
const internal = @import("internal.zig");

const Diagnostics = internal.Diagnostics;
const SheetData = internal.SheetData;

pub const user_needs_synonyms = &[_][]const u8{
    "needs", "user requirements", "stakeholder needs", "user stories",
    "stakeholder requirements", "voice of customer", "voc",
};
pub const requirements_synonyms = &[_][]const u8{
    "reqs", "requirements list", "system requirements", "functional requirements",
    "product requirements", "req", "design inputs",
};
pub const tests_synonyms = &[_][]const u8{
    "test plan", "test cases", "test matrix", "verification",
    "verification tests", "test procedures", "v&v",
};
pub const risks_synonyms = &[_][]const u8{
    "risk register", "risk analysis", "risk assessment", "fmea",
    "hazard analysis", "risk matrix", "risk log",
};
pub const design_inputs_synonyms = &[_][]const u8{
    "design input", "design inputs", "di", "inputs",
};
pub const design_outputs_synonyms = &[_][]const u8{
    "design output", "design outputs", "do", "outputs", "design artifacts",
};
pub const config_items_synonyms = &[_][]const u8{
    "configuration items", "ci", "config items", "controlled items",
    "configuration", "bom",
};
pub const product_tab_synonyms = &[_][]const u8{
    "products", "product configuration", "product config", "configurations", "device configurations",
};
pub const decomposition_tab_synonyms = &[_][]const u8{
    "requirement decomposition", "requirement refinement", "refinement", "hlr-llr",
};

pub fn hasTab(sheets: []const SheetData, canonical_name: []const u8) bool {
    const synonyms = tabSynonymsForCanonical(canonical_name) orelse return false;
    for (sheets) |sheet| {
        if (std.ascii.eqlIgnoreCase(sheet.name, canonical_name)) return true;
        for (synonyms) |syn| {
            if (std.ascii.eqlIgnoreCase(sheet.name, syn)) return true;
        }
    }
    return false;
}

pub fn tabList(sheets: []const SheetData, diag: *Diagnostics) []const u8 {
    if (sheets.len == 0) return "(none)";
    var out: std.ArrayList(u8) = .empty;
    for (sheets, 0..) |s, i| {
        if (i > 0) out.appendSlice(diag.arena.allocator(), ", ") catch return sheets[0].name;
        out.appendSlice(diag.arena.allocator(), s.name) catch return sheets[0].name;
    }
    return out.toOwnedSlice(diag.arena.allocator()) catch sheets[0].name;
}

pub fn resolveTab(sheets: []const SheetData, canonical: []const u8, diag: *Diagnostics) ?SheetData {
    const synonyms = tabSynonymsForCanonical(canonical) orelse return null;

    var t1_match: ?SheetData = null;
    var t1_count: usize = 0;
    for (sheets) |s| {
        if (std.ascii.eqlIgnoreCase(s.name, canonical)) {
            if (t1_match == null) t1_match = s;
            t1_count += 1;
        }
    }
    if (t1_count > 1) {
        diag.warn(diagnostic.E.ambiguous_tab, .tab_discovery, null, null,
            "multiple tabs match '{s}' exactly; using first match '{s}'",
            .{ canonical, t1_match.?.name }) catch {};
    }
    if (t1_match != null) return t1_match;

    var t2_match: ?SheetData = null;
    var t2_syn: []const u8 = "";
    var t2_count: usize = 0;
    outer: for (synonyms) |syn| {
        for (sheets) |s| {
            if (std.ascii.eqlIgnoreCase(s.name, syn)) {
                if (t2_match == null) {
                    t2_match = s;
                    t2_syn = syn;
                } else if (!std.mem.eql(u8, t2_match.?.name, s.name)) {
                    t2_count += 1;
                }
                break :outer;
            }
        }
    }
    if (t2_match != null) {
        for (synonyms) |syn| {
            for (sheets) |s| {
                if (std.ascii.eqlIgnoreCase(s.name, syn) and
                    !std.mem.eql(u8, s.name, t2_match.?.name))
                {
                    t2_count += 1;
                    break;
                }
            }
        }
        if (t2_count > 0) {
            diag.warn(diagnostic.E.ambiguous_tab, .tab_discovery, null, null,
                "multiple tabs match '{s}' synonyms; using '{s}'",
                .{ canonical, t2_match.?.name }) catch {};
        } else {
            diag.info(diagnostic.E.tab_synonym_match, .tab_discovery, null, null,
                "'{s}' tab matched by synonym '{s}'", .{ canonical, t2_syn }) catch {};
        }
        return t2_match;
    }

    var best: ?SheetData = null;
    var best_len: usize = 0;
    var t3_count: usize = 0;
    for (sheets) |s| {
        const s_lower_buf = toLowerBuf(s.name);
        const c_lower_buf = toLowerBuf(canonical);
        const s_lower = s_lower_buf[0..@min(s.name.len, s_lower_buf.len)];
        const c_lower = c_lower_buf[0..@min(canonical.len, c_lower_buf.len)];
        if (std.mem.indexOf(u8, s_lower, c_lower) != null or
            std.mem.indexOf(u8, c_lower, s_lower) != null)
        {
            t3_count += 1;
            if (s.name.len > best_len) {
                best = s;
                best_len = s.name.len;
            }
        }
    }
    if (best) |b| {
        if (t3_count > 1) {
            diag.warn(diagnostic.E.ambiguous_tab, .tab_discovery, null, null,
                "multiple tabs substring-match '{s}'; using longest match '{s}'",
                .{ canonical, b.name }) catch {};
        } else {
            diag.info(diagnostic.E.tab_substring_match, .tab_discovery, null, null,
                "'{s}' tab matched by substring '{s}'", .{ canonical, b.name }) catch {};
        }
        return b;
    }

    var t4_match: ?SheetData = null;
    var t4_count: usize = 0;
    for (sheets) |s| {
        if (levenshtein(s.name, canonical) <= 2) {
            if (t4_match == null) t4_match = s;
            t4_count += 1;
        }
    }
    if (t4_match) |m| {
        if (t4_count > 1) {
            diag.warn(diagnostic.E.ambiguous_tab, .tab_discovery, null, null,
                "multiple tabs fuzzy-match '{s}'; using '{s}'",
                .{ canonical, m.name }) catch {};
        } else {
            diag.info(diagnostic.E.tab_fuzzy_match, .tab_discovery, null, null,
                "'{s}' tab matched by fuzzy match '{s}'", .{ canonical, m.name }) catch {};
        }
        return m;
    }

    return null;
}

pub fn levenshtein(a: []const u8, b: []const u8) usize {
    if (a.len > 31 or b.len > 31) return 999;
    var dp: [32][32]u16 = undefined;
    for (0..a.len + 1) |i| dp[i][0] = @intCast(i);
    for (0..b.len + 1) |j| dp[0][j] = @intCast(j);
    for (1..a.len + 1) |i| {
        for (1..b.len + 1) |j| {
            const cost: u16 = if (std.ascii.toLower(a[i - 1]) == std.ascii.toLower(b[j - 1])) 0 else 1;
            dp[i][j] = @min(dp[i - 1][j] + 1, @min(dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost));
        }
    }
    return dp[a.len][b.len];
}

fn tabSynonymsForCanonical(canonical_name: []const u8) ?[]const []const u8 {
    if (std.ascii.eqlIgnoreCase(canonical_name, "User Needs")) return user_needs_synonyms;
    if (std.ascii.eqlIgnoreCase(canonical_name, "Requirements")) return requirements_synonyms;
    if (std.ascii.eqlIgnoreCase(canonical_name, "Tests")) return tests_synonyms;
    if (std.ascii.eqlIgnoreCase(canonical_name, "Risks")) return risks_synonyms;
    if (std.ascii.eqlIgnoreCase(canonical_name, "Design Inputs")) return design_inputs_synonyms;
    if (std.ascii.eqlIgnoreCase(canonical_name, "Design Outputs")) return design_outputs_synonyms;
    if (std.ascii.eqlIgnoreCase(canonical_name, "Configuration Items")) return config_items_synonyms;
    if (std.ascii.eqlIgnoreCase(canonical_name, "Product")) return product_tab_synonyms;
    if (std.ascii.eqlIgnoreCase(canonical_name, "Decomposition")) return decomposition_tab_synonyms;
    return null;
}

fn toLowerBuf(s: []const u8) [128]u8 {
    var buf: [128]u8 = undefined;
    const len = @min(s.len, buf.len);
    for (s[0..len], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf;
}
