import Foundation
import LegatoMeetingsCLI

// A reader that went away (a closed pipe) is not a crash.
signal(SIGPIPE, SIG_IGN)
exit(await LegatoCLI.run(Array(CommandLine.arguments.dropFirst()), console: .standard))
