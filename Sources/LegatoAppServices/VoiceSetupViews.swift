import CoreTransferable
import Foundation
import LegatoVoiceIdentity
import SwiftUI
import UniformTypeIdentifiers

/// The wording of the voice setup, shared by the iPhone and Mac settings. Settings are only names: the copy never asks
/// the user to change how they speak. Durations come from ``VoiceReadingScript``, so the copy says what the recording does.
public enum VoiceSetupCopy {
    private static let settingReading = Int(VoiceReadingScript.settingReadingSeconds)
    private static let quiet = Int(VoiceReadingScript.quietSeconds)

    public static let toggle = "Reduce background voices (experimental)"
    public static let setupButton = "Set up your voice"
    public static let notSetUp = "Set up your voice once: alone in a quiet room, read a few sentences aloud for about a minute."
    public static let saved = "Your voice is saved on this device."
    public static let setUpFirst = "Set up your voice first."
    public static let about = "Quietly reduces background voices while prioritizing your speech, without holding text back. Experimental: other voices may still get through. First setup downloads a model. Only your voice is saved locally; recordings are kept only if you keep them for testing. Changes apply to the next take. Meetings keep every speaker."
    public static let settingsHeader = "Settings"
    public static var settingsAbout: String {
        "Record your voice where you often dictate, whenever you are there: read the sentences as you normally would, and stay quiet when asked. Each recording is about \(settingReading) seconds of reading and two \(quiet)-second quiet pauses, about a minute in all. The microphone in use is detected and kept with the recording; record again any time."
    }
    public static let addSetting = "Add your own…"
    public static let addSettingTitle = "Name this setting"
    public static let addSettingPlaceholder = "For example: Café"
    public static let nameTaken = "Choose a name that is not in the list yet."
    public static let keepRecordings = "Keep recordings for testing"
    public static let recordingsAbout = "Saves each setup and setting recording that saved your voice on this device, with its sentences, so it can be exported and replayed on a Mac. Off: recordings stay in memory and are discarded."
    public static let exportAll = "Export all recordings"
    public static let saveToFolder = "Save to folder…"
    public static let shareRecording = "Share this recording"
    public static let saveFailed = "The recordings could not be saved. Try again, or choose another folder."
    public static func savedFile(_ url: URL) -> String {
        "Saved \(url.lastPathComponent) in \(url.deletingLastPathComponent().lastPathComponent)."
    }
    public static let deleteVoice = "Delete voice"
    public static let deleteVoiceAbout = "Deletes your voice, every setting recording and kept recording, and turns Reduce background voices off."
    public static let deleted = "Your voice and its recordings are deleted. Reduce background voices is off."
    public static func recordButton(_ row: VoiceSituationRow) -> String { row.isRecorded ? "Record again" : "Record" }
    public static func recordingTitle(_ entry: VoiceRecordingStore.Entry) -> String {
        "\(entry.sidecar.kind == .setup ? "Setup" : entry.sidecar.situationName) · \(entry.sidecar.route.displayName)"
    }
    public static func recordingDetail(_ entry: VoiceRecordingStore.Entry) -> String {
        "\(entry.sidecar.date.formatted(date: .abbreviated, time: .shortened)) · \(Int(entry.seconds.rounded())) s"
    }

    // The recording sheet.
    public static func introduction(firstSetup: Bool) -> String {
        firstSetup
            ? "Find a quiet room where you are alone. You will read sentences aloud for about a minute, one at a time, in your normal voice."
            : "Speak as you normally would here. You will read sentences aloud for about \(settingReading) seconds and stay quiet twice for \(quiet) seconds, so the room is heard as it is."
    }
    public static let firstSentence = "First sentence"
    public static let start = "Start"
    public static let startHint = "Recording starts when you press Start. When you finish a sentence, the next one follows."
    public static let readAloud = "Read aloud"
    public static let nextSentence = "Next sentence"
    public static let stayQuiet = "Stay quiet"
    public static let stayQuietDetail = "Let the room sound as it usually does."
    public static func sentence(_ number: Int, of count: Int) -> String { "Sentence \(number) of \(count)" }
    public static let preparing = "Downloading and preparing the voice model…"
    public static let requestingMicrophone = "Requesting microphone access…"
    public static let startingMicrophone = "Starting the microphone…"
    public static func saving(firstSetup: Bool, name: String) -> String { firstSetup ? "Saving your voice…" : "Saving \(name)…" }
    public static func recorded(firstSetup: Bool, name: String, route: String) -> String {
        firstSetup ? "Your voice is set up and Reduce background voices is on. Record the places where you often dictate to help it further."
            : "Saved \(name) with \(route)."
    }
    public static let tryAgain = "Try again"
    public static let done = "Done"

    // Why a recording failed.
    public static let microphonePermission = "Allow microphone access in system Settings, then try recording again."
    public static let microphoneBusy = "Stop dictation, meetings and the held microphone before recording your voice."
    public static let interrupted = "The microphone stopped sending sound, so the recording ended. Check the microphone and try again."
    public static func tooLittleSpeech(firstSetup: Bool, name: String) -> String {
        "Too little speech was heard to \(firstSetup ? "set up your voice" : "save \(name)"). Read each sentence aloud clearly, then try again."
    }
}

extension VoiceEnrollmentController {
    /// The Reduce background voices toggle: on only with a saved voice. Before setup, a tap explains why it stays off.
    public func optionBinding(_ stored: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { stored.wrappedValue && self.hasProfile }, set: { on in
            guard self.hasProfile else { self.explainSetupFirst(); return }
            self.clearNotice(); stored.wrappedValue = on
        })
    }
}

/// A zip of kept voice recordings, made only when the share sheet or Save to folder asks for it.
public struct VoiceRecordingExport: Transferable, Sendable {
    /// The file name without `.zip`.
    public let name: String
    /// What the share sheet shows.
    public let title: String
    let make: @Sendable () throws -> URL
    public init(name: String, title: String, make: @escaping @Sendable () throws -> URL) {
        self.name = name; self.title = title; self.make = make
    }
    public var fileName: String { name + ".zip" }
    public var preview: SharePreview<Image, Image> {
        SharePreview(title, image: Image(systemName: "waveform"), icon: Image(systemName: "doc.zipper"))
    }
    /// Makes the zip and writes it to `destination`, replacing a file there.
    public func write(to destination: URL) throws {
        let zip = try make()
        defer { try? FileManager.default.removeItem(at: zip) }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: zip, to: destination)
    }
    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { export in SentTransferredFile(try export.make()) }
            .suggestedFileName { $0.fileName }
    }
}

/// The guided recording, shown in a sheet on iPhone and Mac: the first sentence and Start, then one sentence at a
/// time, the quiet countdown and progress, and the outcome. The progress views observe ``VoiceCaptureMeter`` on
/// their own, so its updates redraw only them.
public struct VoiceRecordingGuideView: View {
    let controller: VoiceEnrollmentController
    public init(controller: VoiceEnrollmentController) { self.controller = controller }

    public var body: some View {
        VStack(spacing: 18) {
            if let guide = controller.guide {
                Text(guide.title).font(.title2.weight(.semibold))
                if let route = guide.routeName {
                    Label(route, systemImage: "mic").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("voiceGuide.route")
                }
                content(guide)
                if guide.isActive {
                    Button("Cancel", role: .cancel) { controller.cancel() }.accessibilityIdentifier("voiceGuide.cancel")
                }
            }
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 460, minHeight: 380)
    }

    @ViewBuilder private func content(_ guide: VoiceGuide) -> some View {
        switch guide.phase {
        case .preparing, .saving:
            Spacer(minLength: 0)
            ProgressView()
            Text(guide.status).font(.callout).multilineTextAlignment(.center).accessibilityIdentifier("voiceGuide.status")
            Spacer(minLength: 0)
        case .ready, .starting:
            Text(guide.introduction).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(VoiceSetupCopy.firstSentence).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            prompt(guide)
            Spacer(minLength: 0)
            if guide.phase == .ready {
                Button(VoiceSetupCopy.start) { controller.start() }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("voiceGuide.start")
                Text(VoiceSetupCopy.startHint).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(VoiceSetupCopy.startingMicrophone).font(.callout) }
                    .accessibilityIdentifier("voiceGuide.status")
            }
        case .reading:
            Spacer(minLength: 0)
            Text(VoiceSetupCopy.readAloud).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            prompt(guide)
            VoiceStepBar(meter: controller.meter).frame(maxWidth: 220)
            Button(VoiceSetupCopy.nextSentence) { controller.advance() }.accessibilityIdentifier("voiceGuide.next")
            Spacer(minLength: 0)
            footer(guide)
        case .quiet:
            Spacer(minLength: 0)
            Text(VoiceSetupCopy.stayQuiet).font(.title3.weight(.semibold))
            VoiceQuietCountdown(meter: controller.meter)
            Text(VoiceSetupCopy.stayQuietDetail).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            footer(guide)
        case .saved, .failed:
            Spacer(minLength: 0)
            Image(systemName: guide.phase == .saved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 40)).foregroundStyle(guide.phase == .saved ? Color.green : Color.orange)
                .accessibilityHidden(true)
            Text(guide.status).font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("voiceGuide.result")
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                if guide.phase == .failed {
                    Button(VoiceSetupCopy.tryAgain) { controller.retry() }.accessibilityIdentifier("voiceGuide.retry")
                }
                Button(VoiceSetupCopy.done) { controller.closeGuide() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).accessibilityIdentifier("voiceGuide.done")
            }
        }
    }

    private func prompt(_ guide: VoiceGuide) -> some View {
        Text(guide.prompt ?? "").font(.title3).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("voiceGuide.prompt")
    }

    private func footer(_ guide: VoiceGuide) -> some View {
        VStack(spacing: 8) {
            Text(VoiceSetupCopy.sentence(guide.sentence, of: guide.sentenceCount)).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("voiceGuide.sentence")
            VoiceOverallBar(meter: controller.meter)
        }
    }
}

private struct VoiceStepBar: View {
    let meter: VoiceCaptureMeter
    var body: some View { ProgressView(value: meter.stepProgress) }
}

private struct VoiceOverallBar: View {
    let meter: VoiceCaptureMeter
    var body: some View { ProgressView(value: meter.progress).accessibilityIdentifier("voiceGuide.progress") }
}

private struct VoiceQuietCountdown: View {
    let meter: VoiceCaptureMeter
    var body: some View {
        Text("\(meter.quietRemaining)")
            .font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit()
            .contentTransition(.numericText()).animation(.default, value: meter.quietRemaining)
            .accessibilityIdentifier("voiceGuide.countdown")
    }
}
