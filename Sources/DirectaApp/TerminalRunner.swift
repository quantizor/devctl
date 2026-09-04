import AppKit
import DirectaKit
import Foundation

/** Runs a shell command in a new Terminal window. Terminal is used rather than a
    detached child for two reasons a Homebrew action needs: a GUI-launched app has
    no usable PATH, so a bare `brew` exits 127, while Terminal runs a login shell
    that sources `brew shellenv`; and a `sudo`/password prompt has somewhere to
    go. The window sets a unique title and closes itself on a clean exit, leaving
    a failed run on screen with its output. */
enum TerminalRunner {
    /** `title` names the window so the self-close can find it; keep it a simple
        literal (no quotes) since it is interpolated into AppleScript. */
    static func run(title: String, command: String) {
        let script = """
        #!/bin/sh
        printf '\\033]0;%s\\007' "\(title)"
        \(command)
        status=$?
        if [ "$status" -eq 0 ]; then
          osascript -e 'tell application "Terminal" to close (every window whose name contains "\(title)")' >/dev/null 2>&1 &
        fi
        exit "$status"
        """
        let url = FileManager.default.temporaryDirectory
            .appending(path: "directa-terminal-\(UUID().uuidString).command")
        do {
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: url.path)
        } catch {
            DirectaLog.app.error("could not stage Terminal script: \(error.localizedDescription)")
            return
        }
        _ = LaunchdAdmin.shell("/usr/bin/open", ["-a", "Terminal", url.path])
    }
}
