import AppKit
import SwiftUI

struct IslandEmptyModuleSlot: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(IslandModuleRegistry.self) private var registry
    @State private var isPresentingPicker = false

    let size: CGFloat
    let onOpenModule: (IslandModuleID) -> Void

    var body: some View {
        Button {
            isPresentingPicker = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: size == 30 ? 10 : 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.58))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(0.075)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Choose a module"))
        .help(Text("Choose a module"))
        .popover(isPresented: $isPresentingPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose a module")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)

                ForEach(unpinnedModuleDescriptors) { descriptor in
                    Button {
                        settings.setIslandModuleEnabled(true, id: descriptor.id)
                        settings.setIslandModulePinned(true, id: descriptor.id)
                        onOpenModule(descriptor.id)
                        isPresentingPicker = false
                    } label: {
                        Label(descriptor.title, systemImage: descriptor.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .frame(width: 190)
        }
    }

    private var unpinnedModuleDescriptors: [IslandModuleDescriptor] {
        registry.descriptors.filter {
            !settings.isIslandModulePinned($0.id)
        }
    }
}
