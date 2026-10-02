import Foundation

/// WIRE FORMAT — these case names are written to `state.json` as `tagPreset`.
/// Renaming one silently orphans every tag a user set with it: the value stops
/// decoding, the workspace restores untagged, and the next save overwrites it.
/// Adding cases is safe; renaming needs a migration.
enum WorkspaceColorTag: String, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, gray

    /// Mid-luminance across the board so a stripe holds up on both the light
    /// and dark bundled themes. Where a hue already exists as a design token
    /// the same value is reused, so the sidebar reads as one palette.
    var hex: String {
        switch self {
        case .red: return "E86666"
        case .orange: return "EDA159"
        case .yellow: return "E0BD52"
        case .green: return "73C780"
        case .blue: return "69B0DB"
        case .purple: return "B38CE0"
        case .gray: return "999EA8"
        }
    }

    var title: String { rawValue.capitalized }
}

/// Where a tag's colour came from. This is IDENTITY, not appearance: deriving
/// it by comparing hex against the presets would mean a colour the user picked
/// themselves silently collapses into a preset swatch the moment it happens to
/// match one, and a custom tag would read as "no tag" to anything asking which
/// preset is active.
enum WorkspaceTagColor: Equatable, Sendable {
    case preset(WorkspaceColorTag)
    case custom(hex: String)

    var hex: String {
        switch self {
        case .preset(let preset): return preset.hex
        case .custom(let hex): return hex
        }
    }

    var preset: WorkspaceColorTag? {
        if case .preset(let preset) = self { return preset }
        return nil
    }

    var customHex: String? {
        if case .custom(let hex) = self { return hex }
        return nil
    }
}

/// A workspace's marker: a colour, and optionally a name.
///
/// The seven presets are simply tags with a known colour and no name — the same
/// shape a custom one has. That's Finder's model (its colour labels *are* tags,
/// named after their colours), and it's why picking a swatch and creating a
/// named tag don't turn into two competing marking systems on one row.
///
/// One tag per workspace. Finder allows several per file; a workspace row has a
/// single stripe to spend, and the marker exists to make one row stand out
/// rather than to file it under every category it belongs to.
struct WorkspaceTag: Equatable, Sendable {
    var color: WorkspaceTagColor
    /// Nil for the unnamed presets. Meant for a *category* the user reuses
    /// (`urgent`, `release`) — a workspace's identity already has a name, and
    /// duplicating it here would just put the same string on two hover lines.
    var name: String?

    init(color: WorkspaceTagColor, name: String? = nil) {
        // Normalize here rather than at the call sites: every tag is built
        // through this init, so `#ff8800` and `FF8800` can't end up as two
        // tags that render identically but compare unequal — which would break
        // the swatch toggle, since that compares whole tags.
        switch color {
        case .preset: self.color = color
        case .custom(let hex): self.color = .custom(hex: normalizedTagHex(hex))
        }
        self.name = normalizedTagName(name)
    }

    init(preset: WorkspaceColorTag) {
        self.init(color: .preset(preset))
    }

    var colorHex: String { color.hex }

    /// What the "Custom Tag…" editor saves. `seededPreset` is the preset the
    /// editor opened on, if any; `pickedHex` is whatever the colour well holds
    /// on save.
    ///
    /// A colour the user actually picked stays `.custom` even when it equals a
    /// preset — it's theirs, not a swatch selection they didn't make. But
    /// leaving the well alone isn't picking: the editor seeds from the existing
    /// tag, so an untouched preset round-trips its own hex back out, and
    /// treating that as custom would convert the tag on a name-only edit —
    /// leaving the preset's swatch unselected next to an identical custom one.
    static func edited(
        seededPreset: WorkspaceColorTag?,
        pickedHex: String,
        name: String?
    ) -> WorkspaceTag {
        if let seededPreset, seededPreset.hex.caseInsensitiveCompare(normalizedTagHex(pickedHex)) == .orderedSame {
            return WorkspaceTag(color: .preset(seededPreset), name: name)
        }
        return WorkspaceTag(color: .custom(hex: pickedHex), name: name)
    }

    /// How a tag name is rendered wherever it appears as text. The `#` is added
    /// here and stripped on input by `normalizedTagName`, so the pair stays one
    /// rule instead of a sigil re-interpolated at every tooltip.
    var hashLabel: String? { name.map { "#\($0)" } }
}

/// Uppercased `RRGGBB` with any `#` stripped — the stored form. Validation goes
/// through `parseHexRGB` so this can't drift from what `Color(hex:)` accepts; a
/// value that isn't a colour is returned untouched, because the stripe falling
/// back to gray beats discarding what the user set.
func normalizedTagHex(_ raw: String) -> String {
    // Trim on both paths. Returning the untrimmed input when validation fails
    // would let `" zzz "` and `"zzz"` persist as tags that render identically
    // but compare unequal, which is the equality this function exists to fix.
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard parseHexRGB(trimmed) != nil else { return trimmed }
    return trimmed.hasPrefix("#") ? String(trimmed.dropFirst()).uppercased() : trimmed.uppercased()
}

/// Trims a tag name and drops a leading `#` the user may have typed — the
/// renderer adds the sigil itself, and `##urgent` would be the giveaway that we
/// pasted their input in raw. Blank collapses to `nil`, the same rule
/// `normalizedTitle` applies to every other name in the app.
func normalizedTagName(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let flattened = singleLine(raw).drop { $0 == "#" || $0 == " " }
    return normalizedTitle(String(flattened))
}
