import SwiftUI
import DesignSystem

// MARK: - StoryDeck vignettes (MYR-166 — design/app/tutorials.jsx:9-285)
//
// Mini "screens" built from real DesignSystem primitives — the whole point
// of the story-deck vignettes per CLAUDE.md. Map backdrops are the static
// stylized `MapBackground` (never MapKit). All fixture data mirrors the jsx
// literals verbatim (no `screens.jsx` mocks reused — these vignettes hard-code
// their own small, self-contained demo data exactly like the prototype does).

// MARK: Vignette shell

/// The floating "mini screen" a feature is shown inside (tutorials.jsx:9-17).
struct MiniScreen<Content: View>: View {
    var width: CGFloat = 250
    var height: CGFloat = 250
    var pad: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(pad)
            .frame(width: width, height: height)
            .background(
                LinearGradient(
                    colors: [.mrtVigCardTop, .mrtVigCardBottom],
                    startPoint: HexLogo.tileGradientStart160,
                    endPoint: HexLogo.tileGradientEnd160
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: MRTMetrics.vignetteRadius, style: .continuous)
                    .strokeBorder(Color.mrtVigCardBorder, lineWidth: MRTMetrics.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: MRTMetrics.vignetteRadius, style: .continuous))
            // 0 30px 70px rgba(0,0,0,0.5) — CSS blur halved for SwiftUI sigma.
            .shadow(color: .black.opacity(0.5), radius: 35, x: 0, y: 30)
    }
}

private func rowLabel(_ title: String) -> some View {
    Text(title)
        .font(.system(size: 11, weight: .semibold))
        .tracking(0.8)
        .textCase(.uppercase)
        .foregroundStyle(Color.mrtTextMuted)
}

// MARK: - Owner vignettes

/// tutorials.jsx:22-45 — live map, route, marker, status pill.
struct VigLiveMap: View {
    private let size: CGFloat = 252

    var body: some View {
        MiniScreen(width: size, height: size) {
            ZStack {
                MapBackground(width: size, height: size, seed: 42)
                RouteLine(points: MRTSampleRoute.sliced(into: CGSize(width: size, height: size)), progress: 0.5, lineWidth: 6)
                VehicleMarker(heading: 48, size: 22)
                    .position(x: size * 0.52, y: size * 0.46)
                VStack {
                    Spacer(minLength: 0)
                    statusPill
                }
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 10) {
            PulseDot(color: .mrtDriving, size: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text("Cybercab · Driving")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.mrtText)
                Text("64 mph · 68%")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.mrtTextSec)
            }
            Spacer(minLength: 0)
            (Text("12").font(.system(size: 19, weight: .medium)).monospacedDigit()
                + Text(" min").font(.system(size: 10)))
                .foregroundStyle(Color.mrtGold)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Color.mrtVigStatusPill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.mrtVigControlBorder, lineWidth: MRTMetrics.hairline))
        .padding(12)
    }
}

/// tutorials.jsx:47-75 — recent drives list.
struct VigDrives: View {
    private struct Row { let to: String, sub: String, mi: String, mn: String }
    private let rows: [Row] = [
        Row(to: "Embarcadero Center", sub: "Today · 7:42 AM", mi: "14.6", mn: "29"),
        Row(to: "Half Moon Bay", sub: "Yest. · 9:02 AM", mi: "28.4", mn: "92"),
        Row(to: "Tahoe Donner", sub: "Mon · 6:48 AM", mi: "184", mn: "215"),
    ]

    var body: some View {
        MiniScreen(width: 258, height: 250, pad: 14) {
            VStack(alignment: .leading, spacing: 12) {
                rowLabel("Recent drives")
                VStack(spacing: 9) {
                    ForEach(rows, id: \.to) { row in
                        HStack(spacing: 11) {
                            iconTile("location.fill")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.to).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mrtText).lineLimit(1)
                                Text(row.sub).font(.system(size: 10.5)).foregroundStyle(Color.mrtTextMuted)
                            }
                            Spacer(minLength: 0)
                            VStack(alignment: .trailing, spacing: 1) {
                                (Text(row.mi).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mrtText)
                                    + Text(" mi").font(.system(size: 9)).foregroundStyle(Color.mrtTextMuted))
                                Text("\(row.mn) min").font(.system(size: 10)).foregroundStyle(Color.mrtTextMuted)
                            }
                        }
                        .rowChrome()
                    }
                }
            }
        }
    }
}

/// tutorials.jsx:77-101 — people with map/history access.
struct VigSharing: View {
    private struct Person { let name: String, perm: String, online: Bool }
    private let people: [Person] = [
        Person(name: "Mira Chen", perm: "Live location", online: true),
        Person(name: "Jonas Park", perm: "Live + history", online: true),
        Person(name: "Aanya Iyer", perm: "Live location", online: false),
    ]

    var body: some View {
        MiniScreen(width: 258, height: 250, pad: 14) {
            VStack(alignment: .leading, spacing: 12) {
                rowLabel("People with access")
                VStack(spacing: 9) {
                    ForEach(people, id: \.name) { p in
                        HStack(spacing: 11) {
                            Avatar(name: p.name, size: 32, online: p.online)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mrtText)
                                Text(p.perm).font(.system(size: 10.5)).foregroundStyle(Color.mrtTextMuted)
                            }
                            Spacer(minLength: 0)
                            Text("Shared")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Color.mrtGold)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color.mrtGoldTileFaint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.mrtGoldRing, lineWidth: MRTMetrics.hairline))
                        }
                        .rowChrome(vPad: 9)
                    }
                }
            }
        }
    }
}

/// tutorials.jsx:103-133 — incoming ride request card.
struct VigRequest: View {
    var body: some View {
        MiniScreen(width: 258, height: 250, pad: 16) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    PulseDot(color: .mrtGold, size: 7)
                    Text("Ride request")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.mrtGold)
                }
                .padding(.bottom, 14)

                HStack(spacing: 12) {
                    Avatar(name: "Mira Chen", size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mira wants a ride").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.mrtText)
                        Text("Cybercab · 68% battery").font(.system(size: 11.5)).foregroundStyle(Color.mrtTextSec)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 14)

                HStack(spacing: 9) {
                    Image(systemName: "mappin").font(.system(size: 16)).foregroundStyle(Color.mrtGold)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("SFO · Terminal 2").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mrtText)
                        Text("18.4 mi · ~32 min").font(.system(size: 10.5)).foregroundStyle(Color.mrtTextMuted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(Color.mrtVigRowFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.mrtVigRowBorder, lineWidth: MRTMetrics.hairline))
                .padding(.bottom, 16)

                GeometryReader { geo in
                    let gap: CGFloat = 9
                    let declineWidth = (geo.size.width - gap) * (1 / 2.4)
                    let sendWidth = (geo.size.width - gap) * (1.4 / 2.4)
                    HStack(spacing: gap) {
                        Text("Decline")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.mrtTextSec)
                            .frame(width: declineWidth, height: 40)
                            .background(Color.mrtVigControlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.mrtVigControlBorder, lineWidth: MRTMetrics.hairline))
                        Text("Send the car")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.mrtGoldButtonLabel)
                            .frame(width: sendWidth, height: 40)
                            .background(Color.mrtGold, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .frame(height: 40)
            }
        }
    }
}

/// tutorials.jsx:135-156 — vehicle controls grid.
struct VigClimate: View {
    private struct Control { let icon: String, label: String, val: String, on: Bool }
    private let controls: [Control] = [
        Control(icon: "snowflake", label: "Cool", val: "68°", on: true),
        Control(icon: "sun.max.fill", label: "Heat", val: "Off", on: false),
        Control(icon: "lock.fill", label: "Locked", val: "", on: true),
        Control(icon: "fan", label: "Fan", val: "Auto", on: true),
    ]
    private let columns = [GridItem(.flexible(), spacing: 11), GridItem(.flexible(), spacing: 11)]

    var body: some View {
        MiniScreen(width: 258, height: 250, pad: 16) {
            VStack(alignment: .leading, spacing: 14) {
                rowLabel("Vehicle controls")
                LazyVGrid(columns: columns, spacing: 11) {
                    ForEach(controls, id: \.label) { c in
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: c.icon)
                                .font(.system(size: 22))
                                .foregroundStyle(c.on ? Color.mrtGold : Color.mrtTextSec)
                            Text(c.label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.mrtText)
                            if !c.val.isEmpty {
                                Text(c.val).font(.system(size: 11)).foregroundStyle(c.on ? Color.mrtGold : Color.mrtTextMuted)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(c.on ? Color.mrtGoldCellFill : Color.mrtVigTileOff, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(c.on ? Color.mrtGoldRing : Color.mrtVigRowBorder, lineWidth: MRTMetrics.hairline))
                    }
                }
            }
        }
    }
}

// MARK: - Rider vignettes

/// tutorials.jsx:159-179 — "Where to?" search + suggestions + CTA.
struct VigRequestRide: View {
    var body: some View {
        MiniScreen(width: 258, height: 250, pad: 16) {
            VStack(alignment: .leading, spacing: 0) {
                rowLabel("Where to?").padding(.bottom, 14)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(Color.mrtTextMuted)
                    Text("Ferry Building").font(.system(size: 13.5)).foregroundStyle(Color.mrtText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Color.mrtVigControlFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.mrtVigControlBorder, lineWidth: MRTMetrics.hairline))
                .padding(.bottom, 11)

                ForEach(["Embarcadero Plaza", "Mission · Tartine"], id: \.self) { s in
                    HStack(spacing: 11) {
                        Image(systemName: "mappin").font(.system(size: 15)).foregroundStyle(Color.mrtTextMuted)
                        Text(s).font(.system(size: 12.5)).foregroundStyle(Color.mrtTextSec)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 4)
                }

                HStack(spacing: 8) {
                    Image(systemName: "paperplane.fill").font(.system(size: 15)).foregroundStyle(Color.mrtGoldButtonLabel)
                    Text("Request ride").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.mrtGoldButtonLabel)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.mrtGold, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .padding(.top, 14)
            }
        }
    }
}

/// tutorials.jsx:181-208 — live tracking map + ETA pill.
struct VigTrack: View {
    private let size: CGFloat = 252

    var body: some View {
        MiniScreen(width: size, height: size) {
            ZStack {
                MapBackground(width: size, height: size, seed: 7)
                RouteLine(points: MRTSampleRoute.sliced(into: CGSize(width: size, height: size)), progress: 0.34, lineWidth: 6)
                VehicleMarker(heading: 52, size: 20)
                    .position(x: size * 0.40, y: size * 0.34)
                VStack {
                    trackPill
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var trackPill: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.mrtGoldFillSoft).frame(width: 28, height: 28)
                Image(systemName: "car.fill").font(.system(size: 15)).foregroundStyle(Color.mrtGold)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Alex's Model Y").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mrtText)
                Text("On the way to you").font(.system(size: 10)).foregroundStyle(Color.mrtTextSec)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                Text("3").font(.system(size: 18, weight: .medium)).monospacedDigit().foregroundStyle(Color.mrtGold)
                Text("MIN").font(.system(size: 8.5, weight: .semibold)).tracking(0.6).foregroundStyle(Color.mrtGold)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Color.mrtVigStatusPill, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.mrtVigControlBorder, lineWidth: MRTMetrics.hairline))
        .padding(12)
    }
}

/// tutorials.jsx:210-235 — past rides list.
struct VigRideHistory: View {
    private struct Row { let to: String, sub: String, mi: String }
    private let rows: [Row] = [
        Row(to: "Ferry Building", sub: "Today · with Alex", mi: "4.2"),
        Row(to: "SFO · Terminal 2", sub: "Fri · with Mom", mi: "18.4"),
        Row(to: "Mission · Tartine", sub: "Tue · with Alex", mi: "3.8"),
    ]

    var body: some View {
        MiniScreen(width: 258, height: 250, pad: 14) {
            VStack(alignment: .leading, spacing: 12) {
                rowLabel("Your rides")
                VStack(spacing: 9) {
                    ForEach(rows, id: \.to) { row in
                        HStack(spacing: 11) {
                            iconTile("clock.fill")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.to).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mrtText).lineLimit(1)
                                Text(row.sub).font(.system(size: 10.5)).foregroundStyle(Color.mrtTextMuted)
                            }
                            Spacer(minLength: 0)
                            (Text(row.mi).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mrtText)
                                + Text(" mi").font(.system(size: 9)).foregroundStyle(Color.mrtTextMuted))
                        }
                        .rowChrome()
                    }
                }
            }
        }
    }
}

/// tutorials.jsx:237-261 — Teslas shared with the rider.
struct VigSharedWith: View {
    private struct Car { let owner: String, rel: String, name: String }
    private let fleet: [Car] = [
        Car(owner: "Alex", rel: "Roommate", name: "Model Y"),
        Car(owner: "Mom", rel: "Family", name: "Model Y"),
        Car(owner: "Jordan", rel: "Friend", name: "Model 3"),
    ]

    var body: some View {
        MiniScreen(width: 258, height: 250, pad: 14) {
            VStack(alignment: .leading, spacing: 12) {
                rowLabel("Cars you can ride")
                VStack(spacing: 9) {
                    ForEach(fleet, id: \.owner) { f in
                        HStack(spacing: 11) {
                            Avatar(name: f.owner, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(f.owner)'s \(f.name)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mrtText)
                                Text(f.rel).font(.system(size: 10.5)).foregroundStyle(Color.mrtTextMuted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "car.fill").font(.system(size: 18)).foregroundStyle(Color.mrtGold)
                        }
                        .rowChrome()
                    }
                }
            }
        }
    }
}

/// tutorials.jsx:263-285 — guest capability boundaries.
struct VigSafety: View {
    private let can = ["Request rides", "Watch the live map & ETA", "See your ride history"]
    private let cant = ["Unlock or drive the car", "Change vehicle settings"]

    var body: some View {
        MiniScreen(width: 258, height: 250, pad: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text("You can")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.mrtDriving)
                    .padding(.bottom, 10)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(can, id: \.self) { c in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.mrtDriving)
                            Text(c).font(.system(size: 13)).foregroundStyle(Color.mrtText)
                        }
                    }
                }
                .padding(.bottom, 16)

                Text("You can't")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.mrtTextMuted)
                    .padding(.bottom, 10)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(cant, id: \.self) { c in
                        HStack(spacing: 10) {
                            Image(systemName: "lock.fill").font(.system(size: 14)).foregroundStyle(Color.mrtTextMuted)
                            Text(c).font(.system(size: 13)).foregroundStyle(Color.mrtTextSec)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shared row chrome

private func iconTile(_ systemName: String) -> some View {
    RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(Color.mrtGoldTileFaint)
        .frame(width: 30, height: 30)
        .overlay(Image(systemName: systemName).font(.system(size: 15)).foregroundStyle(Color.mrtGold))
}

private extension View {
    /// The list-row card chrome shared by every vignette's rows
    /// (drives/sharing/history/shared-cars) — background/border/radius.
    func rowChrome(hPad: CGFloat = 12, vPad: CGFloat = 10) -> some View {
        self
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(Color.mrtVigRowFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.mrtVigRowBorder, lineWidth: MRTMetrics.hairline))
    }
}
