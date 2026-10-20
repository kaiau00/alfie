import AppKit
import CoreImage
import Foundation

// Small pieces the connect flow leans on: a QR image for WhatsApp pairing
// and the relaunch that a Full Disk Access grant needs.
//
// A one-shot 127.0.0.1 listener lived here, to catch the OAuth redirect of
// the sign-in flow that was retired (CONNECTORS.md §Google). Nothing else
// needs a loopback server, so the Network import went with it.

enum QRImage {
    /// The payload as a crisp QR code, sized for a sheet.
    static func make(_ payload: String, side: CGFloat = 240) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage else { return nil }
        let scale = side / out.extent.width
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

enum Relaunch {
    /// Start a fresh Moe and leave. macOS reads a Full Disk Access or
    /// Accessibility grant only at launch; the user asked for this by
    /// clicking.
    static func now() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.memoe.app"
        let pid = ProcessInfo.processInfo.processIdentifier
        Log.write("relaunch: quitting pid \(pid); a fresh \(bundleID) opens once it has gone")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script(pid: pid, bundleID: bundleID)]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }

    /// The shell that does it, waiting for THIS process to be gone first.
    ///
    /// It was `sleep 1; open -b …`, and a second is not how long Moe takes
    /// to quit: stopping the gateway alone runs to five seconds when it has
    /// to be killed. `open` then found the old copy still running, brought
    /// it to the front, and that copy finished quitting — so "Quit and
    /// reopen Moe" quit and did not reopen (2026-09-07, the accessibility
    /// screen of onboarding). Polling the pid is the only thing that knows
    /// when the old one has actually gone; the cap is so a wedged quit
    /// does not leave a shell waiting forever. `MOE_OPEN` stands in for
    /// `open` under test (scripts/test-onboarding.sh).
    static func script(pid: Int32, bundleID: String) -> String {
        "i=0; while kill -0 \(pid) 2>/dev/null && [ \"$i\" -lt 300 ]; do sleep 0.2; i=$((i+1)); done; "
            + "\"${MOE_OPEN:-/usr/bin/open}\" -b '\(bundleID)'"
    }
}
