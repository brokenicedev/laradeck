import DumpKit
import SwiftUI

/// Settings → Dumps: servers, editor and message layout.
struct DumpsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var portText = ""
    @State private var dsPortText = ""

    var body: some View {
        @Bindable var service = appState.dumpService

        Form {
            Section {
                Toggle("Receive dumps", isOn: $service.enabled)
                LabeledContent("Port") {
                    TextField("", text: $portText)
                        .frame(width: 80)
                        .onSubmit { apply(portText, to: \.port) { portText = $0 } }
                }
                .disabled(!service.enabled)
                Toggle("Accept ds() calls on a second port", isOn: $service.dsEnabled)
                    .disabled(!service.enabled)
                LabeledContent("ds() port") {
                    TextField("", text: $dsPortText)
                        .frame(width: 80)
                        .onSubmit { apply(dsPortText, to: \.dsPort) { dsPortText = $0 } }
                }
                .disabled(!service.enabled || !service.dsEnabled)
            } header: {
                Text("Server")
            } footer: {
                Text("Dumps are matched to a project by the path of the file that sent them. Press Return to apply a port.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Editor") {
                Picker("Open files in", selection: $service.editor) {
                    ForEach(Editor.allCases) { editor in
                        Text(editor.displayName).tag(editor)
                    }
                }
                if service.editor == .custom {
                    TextField("URL template", text: $service.customEditorURL, prompt: Text("myeditor://open?file=%path&line=%line"))
                }
            }

            Section("Messages") {
                Toggle("Scroll to new messages", isOn: $service.scrollOnLog)
                Toggle("Group identical consecutive messages", isOn: $service.groupDuplicates)
                Toggle("Compact layout", isOn: $service.compactUI)
                Toggle("Show timestamp", isOn: $service.showTimestamp)
                Toggle("Show file name", isOn: $service.showFilename)
                Toggle("Show color indicator", isOn: $service.showColorIndicator)
                Toggle("Show labels", isOn: $service.showLabels)
                Toggle("Add labels to colors", isOn: $service.labelledColors)
                Toggle("Notify when execution is paused", isOn: $service.notifyOnPause)
                Picker("Keep per screen", selection: $service.historyLimit) {
                    ForEach([250, 500, 1000, 5000], id: \.self) { Text("\($0) messages").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            portText = String(appState.dumpService.port)
            dsPortText = String(appState.dumpService.dsPort)
        }
    }

    private func apply(_ text: String, to keyPath: ReferenceWritableKeyPath<DumpService, Int>, reset: (String) -> Void) {
        let service = appState.dumpService
        if let port = Int(text), (1...65535).contains(port) {
            if service[keyPath: keyPath] != port { service[keyPath: keyPath] = port }
        } else {
            reset(String(service[keyPath: keyPath]))
        }
    }
}
