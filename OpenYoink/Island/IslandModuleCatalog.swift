import Foundation
import OpenYoinkModuleCore

@MainActor
enum IslandModuleCatalog {
    static let descriptors: [IslandModuleDescriptor] = [
        .init(id: .shelf, title: String(localized: "Shelf"),
              systemImage: "tray.full", order: 0),
        .init(id: .transfers, title: String(localized: "Transfers"),
              systemImage: "arrow.up.arrow.down", order: 1),
        .init(id: .timer, title: String(localized: "Timer"),
              systemImage: "timer", order: 2),
        .init(id: .battery, title: String(localized: "Battery"),
              systemImage: "battery.75percent", order: 3),
        .init(id: .system, title: String(localized: "System Status"),
              systemImage: "gauge.with.dots.needle.67percent", order: 4),
        .init(id: .media, title: String(localized: "Now Playing"),
              systemImage: "music.note", order: 5),
        .init(id: .folders, title: String(localized: "Quick Access"),
              systemImage: "folder", order: 6),
        .init(id: .clipboard, title: String(localized: "Clipboard History"),
              systemImage: "doc.on.clipboard", order: 7),
        .init(id: .aiUsage, title: String(localized: "AI Usage"),
              systemImage: "chart.line.uptrend.xyaxis", order: 8),
    ]

    static func descriptor(for id: IslandModuleID) -> IslandModuleDescriptor {
        descriptors.first { $0.id == id }!
    }
}
