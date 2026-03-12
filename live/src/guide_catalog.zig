const std = @import("std");
const Allocator = std.mem.Allocator;

const rtmify = @import("rtmify");
const diagnostic = rtmify.diagnostic;
const profile_mod = @import("profile.zig");

pub const GuideGroupId = enum {
    file_and_workbook,
    sheet_mapping,
    validation_and_traceability,
    repo_and_git,
    profile_and_chain_gaps,
};

pub const GuideSurface = enum {
    runtime_diagnostic,
    chain_gap,
};

pub const GuideEntry = struct {
    surface: GuideSurface,
    code: u16,
    code_label: []const u8,
    variant: ?[]const u8,
    anchor: []const u8,
    category: diagnostic.Category,
    title: []const u8,
    summary: []const u8,
    what_checked: []const u8,
    common_causes: []const []const u8,
    what_to_inspect: []const []const u8,
    evidence_kind: []const u8,
};

pub const GuideGroup = struct {
    id: GuideGroupId,
    title: []const u8,
    entries: []GuideEntry,
};

const GroupDef = struct {
    id: GuideGroupId,
    json_id: []const u8,
    title: []const u8,
};

const GROUP_DEFS = [_]GroupDef{
    .{ .id = .file_and_workbook, .json_id = "file-and-workbook", .title = "File and Workbook Diagnostics" },
    .{ .id = .sheet_mapping, .json_id = "sheet-mapping", .title = "Sheet Mapping Diagnostics" },
    .{ .id = .validation_and_traceability, .json_id = "validation-and-traceability", .title = "Validation and Traceability Diagnostics" },
    .{ .id = .repo_and_git, .json_id = "repo-and-git", .title = "Repo and Git Diagnostics" },
    .{ .id = .profile_and_chain_gaps, .json_id = "profile-and-chain-gaps", .title = "Profile and Chain Gaps" },
};

const GapContent = struct {
    summary: []const u8,
    what_checked: []const u8,
    common_causes: []const []const u8,
    what_to_inspect: []const []const u8,
    evidence_kind: []const u8,
};

const FILE_IO_CAUSES = [_][]const u8{
    "The selected workbook path is wrong or no longer exists.",
    "The file is inaccessible because of permissions, locking, or storage issues.",
    "The workbook input is not in the format RTMify expects to ingest.",
};
const FILE_IO_INSPECT = [_][]const u8{
    "Confirm the exact workbook path and filename.",
    "Open the file directly to verify it is present and readable.",
    "Replace the input with a current .xlsx workbook if the file is outdated or malformed.",
};

const WORKBOOK_CONTAINER_CAUSES = [_][]const u8{
    "The workbook was exported in a different spreadsheet format.",
    "The file was renamed to .xlsx without being saved as a real XLSX archive.",
    "Workbook packaging features such as encryption or macros block full ingestion.",
};
const WORKBOOK_CONTAINER_INSPECT = [_][]const u8{
    "Open the workbook in Excel or a compatible editor and verify its true file type.",
    "Re-save the workbook as a plain .xlsx file.",
    "Check whether workbook security settings or archive corruption need to be removed first.",
};

const WORKBOOK_STRUCTURE_CAUSES = [_][]const u8{
    "The workbook archive is incomplete or corrupted.",
    "An export or conversion step dropped required XLSX internals.",
    "A worksheet reference points to content that is no longer present in the archive.",
};
const WORKBOOK_STRUCTURE_INSPECT = [_][]const u8{
    "Re-open and re-save the workbook as a fresh .xlsx file.",
    "Check whether the workbook can be opened without repair prompts.",
    "Verify the expected worksheets still exist in the source workbook.",
};

const SHEET_MAPPING_CAUSES = [_][]const u8{
    "Expected tabs or headers were renamed or removed.",
    "The workbook uses local naming conventions RTMify could not match cleanly.",
    "The sheet layout changed and broke deterministic mapping.",
};
const SHEET_MAPPING_INSPECT = [_][]const u8{
    "Compare the source workbook tab names and headers with the RTMify template.",
    "Rename the affected tabs or columns to the canonical labels where possible.",
    "Review ambiguous matches and clean up duplicates or near-duplicates.",
};

const ROW_PARSING_CAUSES = [_][]const u8{
    "Row identifiers contain formatting artifacts or invalid values.",
    "Duplicate or partial rows are present in the source workbook.",
    "Free-form data entry introduced values RTMify cannot normalize safely.",
};
const ROW_PARSING_INSPECT = [_][]const u8{
    "Review the affected row values in the source sheet.",
    "Normalize IDs and remove accidental punctuation or spacing issues.",
    "Eliminate duplicates or fill in missing IDs before re-running ingest.",
};

const VALIDATION_CAUSES = [_][]const u8{
    "The source data is structurally present but incomplete for traceability review.",
    "Statements or risk fields are too weak, inconsistent, or underspecified.",
    "Trace links remain attached to data that no longer reflects the current intent.",
};
const VALIDATION_INSPECT = [_][]const u8{
    "Review the affected requirement, risk, or test content in the workbook.",
    "Tighten wording, complete missing fields, or correct inconsistent scoring.",
    "Re-check downstream trace links after updating the source data.",
};

const CROSS_REF_CAUSES = [_][]const u8{
    "A referenced ID is misspelled or no longer exists.",
    "The link points at the wrong artifact type for that column.",
    "A source row was skipped earlier, so the target never entered the graph.",
};
const CROSS_REF_INSPECT = [_][]const u8{
    "Find the exact referenced ID in the source workbook and confirm it exists.",
    "Check that the column is pointing to the intended artifact type.",
    "Resolve upstream ingest issues first if the target row was skipped.",
};

const REPO_CAUSES = [_][]const u8{
    "The configured repository path is wrong or no longer available.",
    "The target path is not a readable Git working tree.",
    "Local tooling prerequisites for repository scanning are missing.",
};
const REPO_INSPECT = [_][]const u8{
    "Verify the configured repository path on disk.",
    "Check that the directory contains a usable .git directory and readable files.",
    "Confirm the local Git installation and version meet RTMify requirements.",
};

const GIT_CAUSES = [_][]const u8{
    "Git commands failed, timed out, or returned output RTMify could not parse.",
    "The repository state or platform environment is interfering with Git access.",
    "The scan is touching paths or history that Git cannot currently resolve.",
};
const GIT_INSPECT = [_][]const u8{
    "Run the corresponding git command manually in the affected repository.",
    "Check repository health, path validity, and Git availability.",
    "Retry after resolving local repository or environment issues.",
};

const ANNOTATION_CAUSES = [_][]const u8{
    "Requirement annotations are missing, malformed, or attached to unsupported files.",
    "The file is too large or binary-like for safe annotation scanning.",
    "Annotations reference IDs that do not exist in the current graph.",
};
const ANNOTATION_INSPECT = [_][]const u8{
    "Open the affected source file and review the requirement annotation format.",
    "Confirm the referenced requirement IDs exist exactly as written.",
    "Move annotations into supported comment blocks or supported source files.",
};

fn groupForCategory(category: diagnostic.Category) GuideGroupId {
    return switch (category) {
        .file_io, .workbook_container, .workbook_structure => .file_and_workbook,
        .tab_discovery, .column_mapping, .row_parsing => .sheet_mapping,
        .semantic_validation, .cross_reference => .validation_and_traceability,
        .repo_configuration, .git_integration, .annotation_scanning => .repo_and_git,
        .profile_traceability => .profile_and_chain_gaps,
    };
}

fn groupJsonId(id: GuideGroupId) []const u8 {
    for (GROUP_DEFS) |group| {
        if (group.id == id) return group.json_id;
    }
    unreachable;
}

fn groupTitle(id: GuideGroupId) []const u8 {
    for (GROUP_DEFS) |group| {
        if (group.id == id) return group.title;
    }
    unreachable;
}

fn categoryLabel(category: diagnostic.Category) []const u8 {
    return @tagName(category);
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
}

fn writeJsonField(w: anytype, name: []const u8, value: []const u8) !void {
    try w.print("\"{s}\":\"", .{name});
    try writeJsonString(w, value);
    try w.writeByte('"');
}

fn writeJsonStringArray(w: anytype, items: []const []const u8) !void {
    try w.writeByte('[');
    for (items, 0..) |item, idx| {
        if (idx > 0) try w.writeByte(',');
        try w.writeByte('"');
        try writeJsonString(w, item);
        try w.writeByte('"');
    }
    try w.writeByte(']');
}

fn runtimeText(category: diagnostic.Category) GapContent {
    return switch (category) {
        .file_io => .{
            .summary = "RTMify could not safely open or accept the workbook input.",
            .what_checked = "RTMify validated the workbook file path, size, readability, and basic file-level preconditions before ingest.",
            .common_causes = &FILE_IO_CAUSES,
            .what_to_inspect = &FILE_IO_INSPECT,
            .evidence_kind = "Workbook input",
        },
        .workbook_container => .{
            .summary = "RTMify found a packaging or file-format issue before workbook contents could be trusted.",
            .what_checked = "RTMify inspected the workbook container and archive format to confirm it was a usable XLSX input.",
            .common_causes = &WORKBOOK_CONTAINER_CAUSES,
            .what_to_inspect = &WORKBOOK_CONTAINER_INSPECT,
            .evidence_kind = "Workbook packaging",
        },
        .workbook_structure => .{
            .summary = "RTMify found missing or inconsistent internal workbook structure while loading the XLSX contents.",
            .what_checked = "RTMify checked required XLSX parts and worksheet references before mapping traceability data.",
            .common_causes = &WORKBOOK_STRUCTURE_CAUSES,
            .what_to_inspect = &WORKBOOK_STRUCTURE_INSPECT,
            .evidence_kind = "Workbook structure",
        },
        .tab_discovery, .column_mapping => .{
            .summary = "RTMify could not map part of the workbook layout with enough confidence to treat it as canonical traceability data.",
            .what_checked = "RTMify matched workbook tabs and headers against the expected RTMify data model.",
            .common_causes = &SHEET_MAPPING_CAUSES,
            .what_to_inspect = &SHEET_MAPPING_INSPECT,
            .evidence_kind = "Sheet layout",
        },
        .row_parsing => .{
            .summary = "RTMify found row-level data that could not be normalized into a stable traceability record.",
            .what_checked = "RTMify normalized row IDs and field values before ingesting them into the graph.",
            .common_causes = &ROW_PARSING_CAUSES,
            .what_to_inspect = &ROW_PARSING_INSPECT,
            .evidence_kind = "Workbook row data",
        },
        .semantic_validation => .{
            .summary = "RTMify found content that is present in the workbook but weak, incomplete, or internally inconsistent for traceability review.",
            .what_checked = "RTMify validated requirement, risk, and test semantics after the workbook rows were ingested.",
            .common_causes = &VALIDATION_CAUSES,
            .what_to_inspect = &VALIDATION_INSPECT,
            .evidence_kind = "Traceability content",
        },
        .cross_reference => .{
            .summary = "RTMify found a trace link that does not resolve cleanly in the current graph.",
            .what_checked = "RTMify resolved workbook references against the ingested graph to confirm the linked artifact exists and has the expected type.",
            .common_causes = &CROSS_REF_CAUSES,
            .what_to_inspect = &CROSS_REF_INSPECT,
            .evidence_kind = "Cross-reference resolution",
        },
        .repo_configuration => .{
            .summary = "RTMify could not establish a valid repository configuration for code traceability scanning.",
            .what_checked = "RTMify validated the configured repository path and local Git prerequisites before scanning.",
            .common_causes = &REPO_CAUSES,
            .what_to_inspect = &REPO_INSPECT,
            .evidence_kind = "Repo configuration",
        },
        .git_integration => .{
            .summary = "RTMify reached the repository but could not reliably use Git evidence from it.",
            .what_checked = "RTMify ran Git history and blame queries needed to build current implementation evidence.",
            .common_causes = &GIT_CAUSES,
            .what_to_inspect = &GIT_INSPECT,
            .evidence_kind = "Git history",
        },
        .annotation_scanning => .{
            .summary = "RTMify found an issue while extracting requirement evidence from source annotations.",
            .what_checked = "RTMify scanned supported source files for requirement annotations and mapped them back to the graph.",
            .common_causes = &ANNOTATION_CAUSES,
            .what_to_inspect = &ANNOTATION_INSPECT,
            .evidence_kind = "Code annotations",
        },
        .profile_traceability => .{
            .summary = "RTMify found a profile or chain-gap issue in the current traceability model.",
            .what_checked = "RTMify evaluated the active profile rules against the current graph.",
            .common_causes = &[_][]const u8{},
            .what_to_inspect = &[_][]const u8{},
            .evidence_kind = "Profile traceability",
        },
    };
}

fn appendRuntimeEntries(entries: *std.ArrayList(GuideEntry), alloc: Allocator) !void {
    for (diagnostic.catalog) |catalog_entry| {
        if (catalog_entry.category == .profile_traceability and catalog_entry.code != diagnostic.E.profile_not_configured) continue;

        const content = runtimeText(catalog_entry.category);
        const code_label = try std.fmt.allocPrint(alloc, "E{d}", .{catalog_entry.code});
        const anchor = try std.fmt.allocPrint(alloc, "guide-code-E{d}", .{catalog_entry.code});
        try entries.append(alloc, .{
            .surface = .runtime_diagnostic,
            .code = catalog_entry.code,
            .code_label = code_label,
            .variant = null,
            .anchor = anchor,
            .category = catalog_entry.category,
            .title = catalog_entry.title,
            .summary = content.summary,
            .what_checked = content.what_checked,
            .common_causes = content.common_causes,
            .what_to_inspect = content.what_to_inspect,
            .evidence_kind = content.evidence_kind,
        });
    }
}

fn gapContentFor(gap_type: []const u8) GapContent {
    if (std.mem.eql(u8, gap_type, "orphan_requirement")) return .{
        .summary = "A required traceability handoff is missing for this upstream need or artifact.",
        .what_checked = "RTMify checked whether this upstream node has the required downstream requirement link for the active profile chain.",
        .common_causes = &.{
            "A downstream requirement was never created.",
            "The linking ID is missing or misspelled in the source workbook.",
            "The workbook uses a looser process than the active profile expects.",
        },
        .what_to_inspect = &.{
            "Review the downstream requirement rows that should derive from the affected upstream item.",
            "Check the exact linking ID fields for typos or skipped ingest.",
            "Confirm the active profile matches the intended rigor for this dataset.",
        },
        .evidence_kind = "Traceability chain",
    };
    if (std.mem.eql(u8, gap_type, "untested_requirement")) return .{
        .summary = "The requirement is present in the chain, but RTMify cannot see required verification coverage for it.",
        .what_checked = "RTMify looked for the required testing edge from this requirement to a verification artifact.",
        .common_causes = &.{
            "The requirement is not linked to a test group or verification artifact.",
            "The test artifact exists but the linking ID is missing or incorrect.",
            "Verification data was not ingested into the current graph.",
        },
        .what_to_inspect = &.{
            "Review the requirement's test linkage in the source workbook.",
            "Check that the target test or test group exists and uses the expected ID.",
            "Re-run ingest after fixing missing verification rows.",
        },
        .evidence_kind = "Verification coverage",
    };
    if (std.mem.eql(u8, gap_type, "unmitigated_risk")) return .{
        .summary = "The active profile expects this risk to be linked into the requirement chain, but no mitigation trace is present.",
        .what_checked = "RTMify looked for the required mitigation relationship from the risk to a requirement.",
        .common_causes = &.{
            "Risk rows exist without linked mitigating requirements.",
            "The mitigation reference is stored in a different column or format than expected.",
            "The requirement exists but was skipped or not ingested.",
        },
        .what_to_inspect = &.{
            "Review the risk record and its mitigation linkage fields.",
            "Confirm the target requirement ID exists exactly as referenced.",
            "Check whether the active profile requires stronger risk traceability than the current workbook provides.",
        },
        .evidence_kind = "Risk mitigation",
    };
    if (std.mem.eql(u8, gap_type, "req_without_design_input")) return .{
        .summary = "The requirement is missing the expected design-input allocation step.",
        .what_checked = "RTMify looked for an ALLOCATED_TO relationship from the requirement to a design input.",
        .common_causes = &.{
            "The design-input artifact has not been created yet.",
            "The requirement-to-design-input link is missing or stored under the wrong ID.",
            "The workbook is using the medical profile without the expected design chain data.",
        },
        .what_to_inspect = &.{
            "Review the Design Inputs tab and the requirement allocation column.",
            "Confirm the referenced design-input IDs exist and match exactly.",
            "Check whether the selected profile matches the intended data model.",
        },
        .evidence_kind = "Design allocation",
    };
    if (std.mem.eql(u8, gap_type, "design_input_without_design_output")) return .{
        .summary = "The design input exists, but RTMify cannot see the expected downstream design output.",
        .what_checked = "RTMify looked for a SATISFIED_BY relationship from the design input to a design output.",
        .common_causes = &.{
            "No design output was entered for this design input.",
            "The design output exists but is not linked with the expected ID.",
            "A downstream design row was skipped during ingest.",
        },
        .what_to_inspect = &.{
            "Review the Design Outputs tab and the source design-input column.",
            "Confirm the expected design output IDs are present.",
            "Re-run ingest after correcting missing or mismatched links.",
        },
        .evidence_kind = "Design traceability",
    };
    if (std.mem.eql(u8, gap_type, "design_output_without_source")) return .{
        .summary = "The design output is represented in the graph, but RTMify cannot see current implementation evidence for it.",
        .what_checked = "RTMify looked for current source implementation evidence linked to this design output.",
        .common_causes = &.{
            "Implementation mapping has not been captured yet.",
            "Repo scanning or annotations did not produce the expected source evidence.",
            "The design output points at implementation outside the scanned repositories.",
        },
        .what_to_inspect = &.{
            "Review implementation mapping for the design output.",
            "Check repo scan results and code annotations for the expected requirement or design IDs.",
            "Confirm the relevant repositories are configured and scanned successfully.",
        },
        .evidence_kind = "Implementation evidence",
    };
    if (std.mem.eql(u8, gap_type, "design_output_without_config_control")) return .{
        .summary = "The design output exists, but the expected configuration-control artifact is missing.",
        .what_checked = "RTMify looked for a CONTROLLED_BY relationship from the design output to a configuration item.",
        .common_causes = &.{
            "The configuration item was never recorded.",
            "The design output is linked to the wrong configuration item ID.",
            "Configuration-control data was omitted from the workbook.",
        },
        .what_to_inspect = &.{
            "Review the Configuration Items tab and its source design-output references.",
            "Confirm the design output ID appears exactly where expected.",
            "Add or correct the configuration-control link and re-run ingest.",
        },
        .evidence_kind = "Configuration control",
    };
    if (std.mem.eql(u8, gap_type, "unimplemented_requirement")) return .{
        .summary = "RTMify cannot see current source implementation evidence for the requirement.",
        .what_checked = "RTMify looked for current source implementation evidence linked to the requirement in the active code-traceability graph.",
        .common_causes = &.{
            "Implementation has not been linked to the requirement yet.",
            "Requirement annotations are missing or do not match the exact ID.",
            "The relevant repository has not been configured or scanned successfully.",
        },
        .what_to_inspect = &.{
            "Review source annotations and implementation mappings for the requirement.",
            "Check repo scan diagnostics for failures that would block code evidence.",
            "Confirm the exact requirement ID is used in source comments or mappings.",
        },
        .evidence_kind = "Implementation evidence",
    };
    if (std.mem.eql(u8, gap_type, "hlr_without_llr")) return .{
        .summary = "A higher-level requirement is missing the expected lower-level decomposition step.",
        .what_checked = "RTMify identified this requirement as deriving from an upstream need and then looked for downstream refined requirements.",
        .common_causes = &.{
            "No lower-level requirements were created.",
            "The decomposition exists but uses the wrong relationship or ID field.",
            "The active profile expects decomposition while the current model does not.",
        },
        .what_to_inspect = &.{
            "Review the requirement decomposition structure in the source workbook.",
            "Check REFINED_BY links and child requirement IDs.",
            "Confirm whether the chosen profile should require another requirement level here.",
        },
        .evidence_kind = "Requirement decomposition",
    };
    if (std.mem.eql(u8, gap_type, "llr_without_source")) return .{
        .summary = "The lower-level requirement exists in the decomposition chain, but RTMify cannot see implementation evidence for it.",
        .what_checked = "RTMify looked for current source implementation evidence after confirming the requirement sits downstream in a refined chain.",
        .common_causes = &.{
            "Implementation has not been linked yet.",
            "Source annotations are missing or reference a different ID.",
            "Repository scanning did not produce current source evidence.",
        },
        .what_to_inspect = &.{
            "Check code-traceability results for the affected requirement.",
            "Review annotations in the relevant source files.",
            "Confirm the repositories containing the implementation are configured and scanned.",
        },
        .evidence_kind = "Implementation evidence",
    };
    if (std.mem.eql(u8, gap_type, "source_without_structural_coverage")) return .{
        .summary = "RTMify can see implementation evidence but not the expected current test evidence for that source coverage step.",
        .what_checked = "RTMify looked for test evidence linked to source files that already participate in the implementation chain.",
        .common_causes = &.{
            "Tests exist but are not linked back to the source file.",
            "Verification annotations are missing from the relevant test artifacts.",
            "Current test files were not scanned or not represented in the graph.",
        },
        .what_to_inspect = &.{
            "Review test-file annotations and source-to-test linkage.",
            "Check whether the expected verification artifact is present as a test file.",
            "Re-run scanning after fixing missing verification links.",
        },
        .evidence_kind = "Structural coverage",
    };
    if (std.mem.eql(u8, gap_type, "uncommitted_requirement")) return .{
        .summary = "Implementation evidence exists, but RTMify cannot see commit-message trace tying it back to the requirement.",
        .what_checked = "RTMify found current implementation evidence for the requirement and then looked for commits whose messages explicitly referenced it.",
        .common_causes = &.{
            "Commits never referenced the requirement ID explicitly.",
            "Git history scanning failed or was incomplete.",
            "The implementation exists only in history RTMify did not scan successfully.",
        },
        .what_to_inspect = &.{
            "Review recent commit messages for the exact requirement ID.",
            "Check Git scan diagnostics for failures or timeouts.",
            "Confirm the relevant repository history is available locally.",
        },
        .evidence_kind = "Commit traceability",
    };
    if (std.mem.eql(u8, gap_type, "unattributed_annotation")) return .{
        .summary = "A requirement tag exists in code, but RTMify could not determine who last changed that line.",
        .what_checked = "RTMify found a requirement annotation and then asked Git blame for the latest author information on that line.",
        .common_causes = &.{
            "Git blame failed for the file or line.",
            "The file is untracked, newly generated, or outside usable history.",
            "Path or repository mapping prevented blame from resolving correctly.",
        },
        .what_to_inspect = &.{
            "Check repo scan diagnostics for blame failures or path mismatches.",
            "Confirm the file is tracked and accessible in the configured repository.",
            "Run git blame manually on the affected file and line if needed.",
        },
        .evidence_kind = "Author attribution",
    };
    if (std.mem.eql(u8, gap_type, "missing_asil")) return .{
        .summary = "The active automotive profile expects an ASIL classification for this requirement, but none is present.",
        .what_checked = "RTMify checked the requirement properties for an ASIL value while evaluating automotive profile rules.",
        .common_causes = &.{
            "ASIL was never entered for the requirement.",
            "The value is stored under a different field name or format.",
            "The requirement is being evaluated under a stricter profile than intended.",
        },
        .what_to_inspect = &.{
            "Review the requirement's ASIL field in the source workbook or system of record.",
            "Confirm the value format matches the model RTMify expects.",
            "Check whether the active profile should be automotive for this dataset.",
        },
        .evidence_kind = "Safety classification",
    };
    if (std.mem.eql(u8, gap_type, "asil_inheritance")) return .{
        .summary = "A child requirement has an ASIL value that breaks the configured inheritance rule from its parent.",
        .what_checked = "RTMify compared parent and child requirement ASIL values across refinement relationships.",
        .common_causes = &.{
            "The child requirement was assigned a lower ASIL than its parent.",
            "Parent or child ASIL data is incorrect or stale.",
            "The refinement relationship itself is wrong.",
        },
        .what_to_inspect = &.{
            "Review parent and child ASIL values together.",
            "Confirm the refinement relationship is correct.",
            "Update the requirement data so the decomposition reflects the intended safety allocation.",
        },
        .evidence_kind = "Safety inheritance",
    };
    return .{
        .summary = "RTMify found a missing or inconsistent traceability condition in the active profile.",
        .what_checked = "RTMify evaluated the active profile rules against the current graph.",
        .common_causes = &.{
            "A required trace link is missing.",
            "The current data model does not satisfy the selected profile.",
            "An upstream ingest issue prevented the expected evidence from appearing.",
        },
        .what_to_inspect = &.{
            "Review the affected artifact and its expected upstream and downstream links.",
            "Check source workbook cells or code evidence that should create those links.",
            "Re-run ingest after correcting the missing evidence.",
        },
        .evidence_kind = "Profile traceability",
    };
}

const ChainSeed = struct {
    code: u16,
    title: []const u8,
    gap_type: []const u8,
};

fn appendChainSeedUnique(
    seeds: *std.ArrayList(ChainSeed),
    code: u16,
    title: []const u8,
    gap_type: []const u8,
    alloc: Allocator,
) !void {
    for (seeds.items) |seed| {
        if (seed.code == code and std.mem.eql(u8, seed.title, title) and std.mem.eql(u8, seed.gap_type, gap_type)) return;
    }
    try seeds.append(alloc, .{
        .code = code,
        .title = try alloc.dupe(u8, title),
        .gap_type = try alloc.dupe(u8, gap_type),
    });
}

fn collectChainSeeds(alloc: Allocator) ![]ChainSeed {
    var seeds: std.ArrayList(ChainSeed) = .empty;
    for (profile_mod.profiles) |profile| {
        for (profile.chain_steps) |step| {
            try appendChainSeedUnique(&seeds, step.code, step.title, step.gap_type, alloc);
        }
        for (profile.special_checks) |check| {
            try appendChainSeedUnique(&seeds, check.code, check.title, check.gap_type, alloc);
        }
    }
    return seeds.toOwnedSlice(alloc);
}

fn countSeedsForCode(seeds: []const ChainSeed, code: u16) usize {
    var count: usize = 0;
    for (seeds) |seed| {
        if (seed.code == code) count += 1;
    }
    return count;
}

fn appendChainEntries(entries: *std.ArrayList(GuideEntry), alloc: Allocator) !void {
    const seeds = try collectChainSeeds(alloc);
    for (seeds) |seed| {
        const content = gapContentFor(seed.gap_type);
        const shared_code = countSeedsForCode(seeds, seed.code) > 1;
        const code_label = try std.fmt.allocPrint(alloc, "{d}", .{seed.code});
        const anchor = if (shared_code)
            try std.fmt.allocPrint(alloc, "guide-code-{d}-{s}", .{ seed.code, seed.gap_type })
        else
            try std.fmt.allocPrint(alloc, "guide-code-{d}", .{seed.code});

        try entries.append(alloc, .{
            .surface = .chain_gap,
            .code = seed.code,
            .code_label = code_label,
            .variant = if (shared_code) seed.gap_type else null,
            .anchor = anchor,
            .category = .profile_traceability,
            .title = seed.title,
            .summary = content.summary,
            .what_checked = content.what_checked,
            .common_causes = content.common_causes,
            .what_to_inspect = content.what_to_inspect,
            .evidence_kind = content.evidence_kind,
        });
    }
}

fn entryLessThan(_: void, a: GuideEntry, b: GuideEntry) bool {
    if (a.code != b.code) return a.code < b.code;
    return std.mem.lessThan(u8, a.title, b.title);
}

pub fn collectGuideGroups(alloc: Allocator) ![]GuideGroup {
    var all_entries: std.ArrayList(GuideEntry) = .empty;
    try appendRuntimeEntries(&all_entries, alloc);
    try appendChainEntries(&all_entries, alloc);

    var groups: std.ArrayList(GuideGroup) = .empty;
    for (GROUP_DEFS) |group_def| {
        var group_entries: std.ArrayList(GuideEntry) = .empty;
        for (all_entries.items) |entry| {
            if (groupForCategory(entry.category) == group_def.id) {
                try group_entries.append(alloc, entry);
            }
        }
        std.mem.sort(GuideEntry, group_entries.items, {}, entryLessThan);
        try groups.append(alloc, .{
            .id = group_def.id,
            .title = group_def.title,
            .entries = try group_entries.toOwnedSlice(alloc),
        });
    }
    return groups.toOwnedSlice(alloc);
}

fn appendEntryJson(out: *std.ArrayList(u8), entry: GuideEntry, alloc: Allocator) !void {
    const w = out.writer(alloc);
    try w.writeByte('{');
    try writeJsonField(w, "surface", @tagName(entry.surface));
    try w.print(",\"code\":{d}", .{entry.code});
    try w.writeByte(',');
    try writeJsonField(w, "code_label", entry.code_label);
    try w.writeAll(",\"variant\":");
    if (entry.variant) |variant| {
        try w.writeByte('"');
        try writeJsonString(w, variant);
        try w.writeByte('"');
    } else {
        try w.writeAll("null");
    }
    try w.writeByte(',');
    try writeJsonField(w, "anchor", entry.anchor);
    try w.writeByte(',');
    try writeJsonField(w, "category", categoryLabel(entry.category));
    try w.writeByte(',');
    try writeJsonField(w, "title", entry.title);
    try w.writeByte(',');
    try writeJsonField(w, "summary", entry.summary);
    try w.writeByte(',');
    try writeJsonField(w, "what_checked", entry.what_checked);
    try w.writeAll(",\"common_causes\":");
    try writeJsonStringArray(w, entry.common_causes);
    try w.writeAll(",\"what_to_inspect\":");
    try writeJsonStringArray(w, entry.what_to_inspect);
    try w.writeByte(',');
    try writeJsonField(w, "evidence_kind", entry.evidence_kind);
    try w.writeByte('}');
}

pub fn guideErrorsJson(alloc: Allocator) ![]const u8 {
    const groups = try collectGuideGroups(alloc);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const w = out.writer(alloc);
    try w.writeAll("{\"groups\":[");
    for (groups, 0..) |group, gi| {
        if (gi > 0) try w.writeByte(',');
        try w.writeByte('{');
        try writeJsonField(w, "id", groupJsonId(group.id));
        try w.writeByte(',');
        try writeJsonField(w, "title", group.title);
        try w.writeAll(",\"entries\":[");
        for (group.entries, 0..) |entry, ei| {
            if (ei > 0) try w.writeByte(',');
            try appendEntryJson(&out, entry, alloc);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
    return alloc.dupe(u8, out.items);
}

const testing = std.testing;

test "collectGuideGroups covers every runtime code and chain gap variant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const groups = try collectGuideGroups(alloc);

    var runtime_count: usize = 0;
    for (diagnostic.all_codes) |code| {
        const category = diagnostic.categoryFor(code).?;
        if (category == .profile_traceability and code != diagnostic.E.profile_not_configured) continue;
        var found: usize = 0;
        for (groups) |group| {
            for (group.entries) |entry| {
                if (entry.surface == .runtime_diagnostic and entry.code == code) found += 1;
            }
        }
        try testing.expectEqual(@as(usize, 1), found);
        runtime_count += 1;
    }

    const seeds = try collectChainSeeds(alloc);
    for (seeds) |seed| {
        var found: usize = 0;
        for (groups) |group| {
            for (group.entries) |entry| {
                if (entry.surface == .chain_gap and entry.code == seed.code and std.mem.eql(u8, entry.title, seed.title)) {
                    const variant = entry.variant orelse seed.gap_type;
                    if (std.mem.eql(u8, variant, seed.gap_type)) found += 1;
                }
            }
        }
        try testing.expectEqual(@as(usize, 1), found);
    }
    try testing.expect(runtime_count > 0);
}

test "collectGuideGroups has unique anchors and exact lookup keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const groups = try collectGuideGroups(alloc);
    var anchors: std.StringHashMap(void) = .init(alloc);
    defer anchors.deinit();
    var keys: std.StringHashMap(void) = .init(alloc);
    defer keys.deinit();

    for (groups) |group| {
        for (group.entries) |entry| {
            try testing.expect(!anchors.contains(entry.anchor));
            try anchors.put(entry.anchor, {});

            const key = if (entry.surface == .runtime_diagnostic)
                try std.fmt.allocPrint(alloc, "diag:{s}", .{entry.code_label})
            else if (entry.variant) |variant|
                try std.fmt.allocPrint(alloc, "gap:{d}:{s}", .{ entry.code, variant })
            else
                try std.fmt.allocPrint(alloc, "gap:{d}", .{entry.code});
            try testing.expect(!keys.contains(key));
            try keys.put(key, {});
        }
    }
}

test "guideErrorsJson includes grouped response shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const json = try guideErrorsJson(alloc);
    try testing.expect(std.mem.indexOf(u8, json, "\"groups\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"code_label\":\"E901\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"anchor\":\"guide-code-E901\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"surface\":\"runtime_diagnostic\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"surface\":\"chain_gap\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"category\":\"repo_configuration\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"common_causes\":[") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"what_to_inspect\":[") != null);
}
