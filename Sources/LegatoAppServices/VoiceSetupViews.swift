import CoreTransferable
import Foundation
import LegatoVoiceIdentity
import SwiftUI
import UniformTypeIdentifiers

/// The wording of the voice setup, shared by the iPhone and Mac settings. Settings are only names: the copy never asks
/// the user to change how they speak.
public enum VoiceSetupCopy {
    public static let toggle = "Reduce background voices (experimental)"
    public static let setupButton = "Set up your voice"
    public static let notSetUp = "Set up your voice once: read a few sentences aloud for about a minute, alone in a quiet room."
    public static let saved = "Your voice is saved on this device."
    public static let about = "Quietly reduces background voices while prioritizing your speech, without holding text back. Experimental: other voices may still get through. First setup downloads a model. Only your voice is saved locally; recordings are kept only if you keep them for testing. Changes apply to the next take. Meetings keep every speaker."
    public static let settingsHeader = "Settings"
    public static let settingsAbout = "Record your voice where you often dictate, whenever you are there: read the sentences as you normally would, and stay quiet when asked. Each takes about a minute. The microphone in use is detected and kept with the recording; record again any time."
    public static let addSetting = "Add your own…"
    public static let addSettingTitle = "Name this setting"
    public static let addSettingPlaceholder = "For example: Café"
    public static let keepRecordings = "Keep recordings for testing"
    public static let recordingsAbout = "Saves each setup and setting recording on this device with its sentences, so it can be exported and replayed on a Mac. Off: recordings stay in memory and are discarded."
    public static let exportAll = "Export all recordings"
    public static let deleteVoice = "Delete voice"
    public static let deleteVoiceAbout = "Deletes your voice, every setting recording and kept recording, and turns Reduce background voices off."
    public static func recordButton(_ row: VoiceSituationRow) -> String { row.isRecorded ? "Record again" : "Record" }
    public static func recordingTitle(_ entry: VoiceRecordingStore.Entry) -> String {
        "\(entry.sidecar.kind == .setup ? "Setup" : entry.sidecar.situationName) · \(entry.sidecar.route.displayName)"
    }
    public static func recordingDetail(_ entry: VoiceRecordingStore.Entry) -> String {
        "\(entry.sidecar.date.formatted(date: .abbreviated, time: .shortened)) · \(Int(entry.seconds.rounded())) s"
    }
}

/// A zip of kept voice recordings, made only when the share sheet asks for it.
public struct VoiceRecordingExport: Transferable, Sendable {
    public let name: String
    let make: @Sendable () throws -> URL
    public init(name: String, make: @escaping @Sendable () throws -> URL) { self.name = name; self.make = make }
    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { export in SentTransferredFile(try export.make()) }
            .suggestedFileName { $0.name + ".zip" }
    }
}

/// The guided recording, shown in a sheet on iPhone and Mac: one sentence at a time, the quiet countdown and progress.
public struct VoiceRecordingGuideView: View {
    let controller: VoiceEnrollmentController
    public init(controller: VoiceEnrollmentController) { self.controller = controller }

    public var body: some View {
        VStack(spacing: 18) {
            if let guide = controller.guide {
                Text(guide.title).font(.title2.weight(.semibold))
                Text(guide.introduction).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if let route = guide.routeName {
                    Label(route, systemImage: "mic").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("voiceGuide.route")
                }
                Spacer(minLength: 0)
                if guide.isCapturing {
                    if guide.isQuiet {
                        Text("Stay quiet").font(.title3.weight(.semibold))
                        Text("\(guide.quietRemaining)")
                            .font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText()).accessibilityIdentifier("voiceGuide.countdown")
                        Text("Let the room sound as it usually does.").font(.callout).foregroundStyle(.secondary)
                    } else if let prompt = guide.prompt {
                        Text("Read aloud").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(prompt).font(.title3).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("voiceGuide.prompt")
                        ProgressView(value: guide.stepProgress).frame(maxWidth: 220)
                        Button("Next sentence") { controller.advance() }.accessibilityIdentifier("voiceGuide.next")
                    }
                    Spacer(minLength: 0)
                    Text("Sentence \(max(1, guide.sentence)) of \(guide.sentenceCount)").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("voiceGuide.sentence")
                    ProgressView(value: guide.progress).accessibilityIdentifier("voiceGuide.progress")
                } else {
                    ProgressView()
                    Text(guide.status).font(.callout).accessibilityIdentifier("voiceGuide.status")
                    Spacer(minLength: 0)
                }
                Button("Cancel", role: .cancel) { controller.cancel() }.accessibilityIdentifier("voiceGuide.cancel")
            }
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 460, minHeight: 380)
        .animation(.default, value: controller.guide?.quietRemaining)
    }
}
