import AppKit
import NotchbotCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, content, notifications, integration, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .content: "Content"
        case .notifications: "Notifications"
        case .integration: "Integration"
        case .advanced: "Advanced"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .content: "rectangle.stack"
        case .notifications: "bell"
        case .integration: "puzzlepiece.extension"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

/// Observable wrapper around `Preferences`: every change is persisted immediately (no Save button).
@MainActor @Observable
final class AppSettings {
    var prefs: Preferences { didSet { prefs.save(); onChange?(oldValue, prefs) } }
    var tab: SettingsTab = .general
    var confirmReset = false
    var onChange: ((Preferences, Preferences) -> Void)?

    init(defaults: UserDefaults = .standard) { prefs = Preferences.load(defaults) }
    func reset() { prefs = Preferences() }
}

// MARK: - Window

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model, settings: model.settings)))
            w.title = "Notchbot Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.setContentSize(NSSize(width: 540, height: 520))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Views

struct SettingsView: View {
    let model: AppModel
    @Bindable var settings: AppSettings

    var body: some View {
        TabView(selection: $settings.tab) {
            GeneralTab(settings: settings).tabItem { Label("General", systemImage: SettingsTab.general.symbol) }.tag(SettingsTab.general)
            ContentTab(model: model, settings: settings).tabItem { Label("Content", systemImage: SettingsTab.content.symbol) }.tag(
                SettingsTab.content)
            NotificationsTab(settings: settings).tabItem { Label("Notifications", systemImage: SettingsTab.notifications.symbol) }.tag(
                SettingsTab.notifications)
            IntegrationTab(model: model, settings: settings).tabItem { Label("Integration", systemImage: SettingsTab.integration.symbol) }
                .tag(SettingsTab.integration)
            AdvancedTab(settings: settings).tabItem { Label("Advanced", systemImage: SettingsTab.advanced.symbol) }.tag(
                SettingsTab.advanced)
        }
        .frame(width: 540, height: 520)
    }
}

/// Section footer text: small, secondary, explains the consequence of a setting.
private func hint(_ s: String) -> some View { Text(s).font(.caption).foregroundStyle(.secondary) }

struct GeneralTab: View {
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
            Section {
                IslandSizePicker(size: $settings.prefs.islandSize)
            } header: {
                Text("Island size")
            } footer: {
                hint("Scales the island's text and icons. Larger sizes show fewer sessions per page.")
            }

            Section {
                Toggle("Raise the island when something needs you", isOn: $settings.prefs.autoExpandOnEvents)
                Picker("Forget idle sessions after", selection: $settings.prefs.sessionRetention) {
                    Text("1 hour").tag(Preferences.SessionRetention.oneHour)
                    Text("4 hours").tag(Preferences.SessionRetention.fourHours)
                    Text("12 hours").tag(Preferences.SessionRetention.twelveHours)
                    Text("1 day").tag(Preferences.SessionRetention.oneDay)
                }
            } header: {
                Text("Behavior")
            } footer: {
                hint(
                    "The island is a macOS Live Activity, so the system decides its size, position and when it expands. Approval requests and questions always raise it. Finished results are marked reviewed when you reply in that session or tap Done."
                )
            }
        }
        .formStyle(.grouped)
    }
}

/// A stepped slider like the macOS display picker: ends labelled by words, ticks for each step, no numbers.
struct IslandSizePicker: View {
    @Binding var size: Preferences.IslandSize
    private var steps: Double { Double(Preferences.IslandSize.allCases.count - 1) }
    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .lastTextBaseline) {
                Text("A").font(.system(size: 11))
                Spacer()
                Text("A").font(.system(size: 19))
            }
            Slider(
                value: Binding(
                    get: { Double(size.rawValue) },
                    set: { size = Preferences.IslandSize(rawValue: Int($0.rounded())) ?? .standard }),
                in: 0...steps, step: 1)
            ZStack {
                Text(size.title).fontWeight(.semibold).foregroundStyle(.primary)
                HStack {
                    Text("Smaller")
                    Spacer()
                    Text("Larger")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct ContentTab: View {
    let model: AppModel
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
            Section {
                Toggle("Your prompt", isOn: $settings.prefs.showPrompt)
                Toggle("Subagents", isOn: $settings.prefs.showSubagents)
                Toggle("Context meter and changed lines", isOn: $settings.prefs.showContextMeter)
                Toggle("Usage and quota", isOn: $settings.prefs.showUsageCard)
            } header: {
                Text("Show on each session")
            } footer: {
                hint("Names, status, and approval requests are always shown.")
            }

            Section {
                Picker("Usage card shows", selection: $settings.prefs.usageDisplay) {
                    Text("Plan limits (%)").tag(Preferences.UsageDisplay.percent)
                    Text("Token counts").tag(Preferences.UsageDisplay.tokens)
                }
                Picker("Dollar cost", selection: $settings.prefs.costDisplay) {
                    Text("Automatic").tag(Preferences.CostDisplay.auto)
                    Text("Always").tag(Preferences.CostDisplay.always)
                    Text("Never").tag(Preferences.CostDisplay.never)
                }
                LabeledContent("Detected plan") { Text(model.planDescription).foregroundStyle(.secondary) }
            } header: {
                Text("Cost")
            } footer: {
                hint(
                    "Automatic hides dollars on Pro and Max, where usage is limited by quota, and shows them for API billing. Claude Code's dollar figure is an estimate at list prices."
                )
            }
        }
        .formStyle(.grouped)
    }
}

struct NotificationsTab: View {
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
            Section {
                Toggle("Approval needed", isOn: $settings.prefs.notifyOnPermission)
                Toggle("Waiting for your input", isOn: $settings.prefs.notifyOnInput)
                Toggle("Turn finished", isOn: $settings.prefs.notifyOnFinished)
                Toggle("Turn failed", isOn: $settings.prefs.notifyOnFailed)
            } header: {
                Text("Notify me when")
            }

            Section {
                Toggle("Play a sound", isOn: $settings.prefs.soundEnabled)
                Toggle("Show system notifications", isOn: $settings.prefs.systemNotifications)
                Toggle("Include details in banners", isOn: $settings.prefs.bannerDetails)
                    .disabled(!settings.prefs.systemNotifications)
            } header: {
                Text("How")
            } footer: {
                hint(
                    "Details are the command or a snippet of Claude's reply, which can appear on a locked screen. The island itself always reflects every state; these only control extra alerts."
                )
            }
        }
        .formStyle(.grouped)
    }
}

struct IntegrationTab: View {
    let model: AppModel
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
            Section {
                LabeledContent("Hooks") {
                    Label(
                        model.hooksInstalled ? "Installed" : "Not installed",
                        systemImage: model.hooksInstalled ? "checkmark.circle.fill" : "circle.dashed"
                    )
                    .foregroundStyle(model.hooksInstalled ? .green : .secondary)
                }
                HStack {
                    Button(model.hooksInstalled ? "Reinstall" : "Install hooks") { model.installHooks() }
                    if model.hooksInstalled { Button("Uninstall", role: .destructive) { model.uninstallHooks() } }
                }
                if model.hooksOutdated {
                    Label(
                        "An update is available: your hooks predate SubagentStart, so subagents are noticed late.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.callout).foregroundStyle(.orange)
                }
                Toggle("Approve permissions from the island", isOn: $settings.prefs.approveFromIsland)
            } header: {
                Text("Claude Code hooks")
            } footer: {
                hint(
                    "Hooks are merged into ~/.claude/settings.json next to any you already have; a backup is kept. When approving from the island, Claude waits for your answer (up to 10 minutes); choose “Ask in terminal” to fall back to the normal prompt."
                )
            }

            Section {
                LabeledContent("Quota gauges") {
                    Label(
                        model.statusLineInstalled ? "Enabled" : "Off",
                        systemImage: model.statusLineInstalled ? "checkmark.circle.fill" : "circle.dashed"
                    )
                    .foregroundStyle(model.statusLineInstalled ? .green : .secondary)
                }
                Button(model.statusLineInstalled ? "Disable quota gauges" : "Enable quota gauges") {
                    model.statusLineInstalled ? model.uninstallStatusLine() : model.installStatusLine()
                }
            } header: {
                Text("Subscription quota")
            } footer: {
                hint(
                    "Reads the 5-hour and weekly limits from Claude Code's status line. If you already use a custom status line it is left untouched."
                )
            }

            if let e = model.lastError {
                Section { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedTab: View {
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
            Section {
                Toggle("Log raw hook events", isOn: $settings.prefs.logRawEvents)
                Button("Show log in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Paths.supportDir.appendingPathComponent("events.jsonl")])
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                hint("Writes every hook event to events.jsonl, including prompt text and tool inputs. Leave off unless you are debugging.")
            }

            Section {
                Button("Reset all settings…", role: .destructive) { settings.confirmReset = true }
            } header: {
                Text("Reset")
            }

            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                Text("Notchbot is an unofficial companion for Claude Code. It is not affiliated with or endorsed by Anthropic.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $settings.confirmReset) {
            Button("Reset", role: .destructive) { settings.reset() }
            Button("Cancel", role: .cancel) {}
        }
    }
}
