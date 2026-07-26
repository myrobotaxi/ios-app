import SwiftUI

// MARK: - Stat cluster (components.jsx StatCol / StatRow) + KV + divider

/// One stat: 23pt light numeric value (+ optional unit) over a 10pt
/// uppercase label. Apple spaces these with whitespace, never hard rules.
public struct StatCol: View {
    private let label: String
    private let value: String
    private let unit: String?
    private let accent: Bool
    private let alignment: HorizontalAlignment

    public init(
        label: String,
        value: String,
        unit: String? = nil,
        accent: Bool = false,
        alignment: HorizontalAlignment = .center
    ) {
        self.label = label
        self.value = value
        self.unit = unit
        self.accent = accent
        self.alignment = alignment
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: 7) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 23, weight: .light))
                    .monospacedDigit()
                    .tracking(-0.6)
                    .foregroundStyle(accent ? Color.mrtGold : Color.mrtText)
                if let unit {
                    Text(unit)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.mrtTextMuted)
                }
            }
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(Color.mrtTextMuted)
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .leading: .leading
        case .trailing: .trailing
        default: .center
        }
    }
}

/// Clean stat cluster — equal-width columns, top-aligned, 8pt gaps.
public struct StatRow<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) { content }
    }
}

/// How an absent value reads (MYR-255). `.syncing` = a real, contracted field
/// whose live value hasn't streamed in yet (auto-populates once telemetry /
/// the MYR-252 read-back arrives). `.unavailable` = no data source exists yet
/// — a backend-field gap (full VIN, software version, tire pressures). Both
/// render the same subtle em-dash + muted caption so an honest unknown reads as
/// intentional, never as a broken/empty row (client TestFlight feedback, fb6).
public enum MRTValueAbsence {
    case syncing
    case unavailable
    /// A value that only exists after the car is driven — e.g. TPMS tire
    /// pressures, which Tesla surfaces on the stream during/after a drive and
    /// are absent on a cold parked read (MYR-279). Guides the owner ("drive
    /// first") instead of the bare, confusing "Unavailable".
    case afterDrive

    var caption: String {
        switch self {
        case .syncing: return "Syncing"
        case .unavailable: return "Unavailable"
        case .afterDrive: return "Available after your next drive"
        }
    }
}

/// The design's em-dash for an unavailable value, exported so every
/// honest-unknown surface (control tiles, climate, detail rows) shares one glyph.
public let mrtUnavailableDash = "\u{2014}"

/// Number formatting helpers for hero/detail stats (MYR-255). Grouping uses a
/// fixed comma separator to match the prototype's "42,184"-style literals
/// regardless of device locale.
public enum MRTNumber {
    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.groupingSize = 3
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 0
        return f
    }()

    /// e.g. `42184` → `"42,184"`.
    public static func grouped(_ value: Int) -> String {
        grouping.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// The shared honest-unknown treatment (MYR-255): a subtle em-dash + a muted
/// caption, sized to sit where a value would.
public struct MRTUnavailableValue: View {
    private let absence: MRTValueAbsence

    public init(_ absence: MRTValueAbsence) {
        self.absence = absence
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(mrtUnavailableDash)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.mrtTextMuted)
            Text(absence.caption)
                .font(.system(size: 11, weight: .medium))
                .tracking(0.2)
                .foregroundStyle(Color.mrtTextMuted)
        }
    }
}

/// Dense key-value row for settings/details lists.
public struct KV: View {
    private let label: String
    private let value: String?
    private let gold: Bool
    /// How an absent (nil/blank) value renders (MYR-255).
    private let absence: MRTValueAbsence

    public init(label: String, value: String, gold: Bool = false) {
        self.label = label
        self.value = value
        self.gold = gold
        self.absence = .unavailable
    }

    /// Nullable value: nil (or blank) renders the honest-unknown treatment
    /// (em-dash + `absence.caption`) rather than a bare, broken-looking empty row.
    public init(label: String, value: String?, absence: MRTValueAbsence, gold: Bool = false) {
        self.label = label
        let trimmed = value?.trimmingCharacters(in: .whitespaces)
        self.value = (trimmed?.isEmpty ?? true) ? nil : value
        self.gold = gold
        self.absence = absence
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color.mrtTextSec)
            Spacer(minLength: 12)
            if let value {
                Text(value)
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(gold ? Color.mrtGold : Color.mrtText)
            } else {
                MRTUnavailableValue(absence)
            }
        }
        .padding(.vertical, 8)
    }
}

/// 1pt section divider (`Divider` in the jsx — MRT-prefixed to avoid the
/// SwiftUI.Divider collision).
public struct MRTDivider: View {
    private let pad: CGFloat

    public init(pad: CGFloat = 14) {
        self.pad = pad
    }

    public var body: some View {
        Rectangle()
            .fill(Color.mrtBorder)
            .frame(height: 1)
            .padding(.vertical, pad)
    }
}
