import SwiftUI

struct AddCollectionSheet: View {
    let kind: FontCollection.Kind
    var onCreate: (String, String) -> Void
    var cancel: () -> Void

    @State private var name: String = ""
    @State private var selectedColor: String = "#7DD3FC"

    private let presetColors: [String] = [
        "#7DD3FC", "#A78BFA", "#F472B6", "#FB923C",
        "#FACC15", "#4ADE80", "#22D3EE", "#F87171"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind == .project ? "New Project" : "New Palette")
                .font(.title3).bold()

            Text(kind == .project
                 ? "Group the fonts you're using on a specific project. Toggle them all at once from the sidebar."
                 : "Save a reusable palette — e.g. 'Brand Guidelines' or 'Editorial'. Toggle on/off together.")
                .font(.caption).foregroundStyle(.secondary)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Color").font(.caption).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(presetColors, id: \.self) { hex in
                        Button { selectedColor = hex } label: {
                            ZStack {
                                Circle().fill(Color(hex: hex) ?? .gray).frame(width: 20, height: 20)
                                if selectedColor == hex {
                                    Circle().stroke(Color.primary, lineWidth: 2).frame(width: 22, height: 22)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { cancel() }
                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { onCreate(trimmed, selectedColor) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
