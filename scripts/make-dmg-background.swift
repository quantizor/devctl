#!/usr/bin/env swift
/** Renders the DMG background (1x + 2x PNGs) that tells the user to double-click
    the app. Generated at build time so no binary asset lives in the repo.
    Usage: make-dmg-background.swift <output-directory> */
import AppKit
import Foundation

let width: CGFloat = 560
let height: CGFloat = 380

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("make-dmg-background: missing output directory\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])

func render(scale: CGFloat) -> Data? {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale),
            pixelsHigh: Int(height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
    else { return nil }
    rep.size = NSSize(width: width, height: height)

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    NSColor(calibratedWhite: 0.976, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    /** Hairline frame: quiet instrument-panel edge, not chrome. */
    NSColor(calibratedWhite: 0.902, alpha: 1).setStroke()
    let frame = NSBezierPath(rect: NSRect(x: 0.5, y: 0.5, width: width - 1, height: height - 1))
    frame.lineWidth = 1
    frame.stroke()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center

    /** The context has a bottom-left origin, so each rect's y is measured up from
        the bottom while the text itself lays out downward from the rect's top.
        The Finder icon sits centered at 125 points down from the window's top. */
    let heading = NSAttributedString(
        string: "Double-click to install",
        attributes: [
            .font: NSFont.systemFont(ofSize: 19, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.153, alpha: 1),
            .paragraphStyle: paragraph,
        ])
    heading.draw(in: NSRect(x: 40, y: height - 240 - 28, width: width - 80, height: 28))

    let detail = NSAttributedString(
        string:
            "It sets up the command line tool, background service, and menu bar app.\nYou will see exactly what changes and confirm before anything runs.",
        attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.435, alpha: 1),
            .paragraphStyle: paragraph,
        ])
    detail.draw(in: NSRect(x: 40, y: height - 276 - 44, width: width - 80, height: 44))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

do {
    try FileManager.default.createDirectory(
        at: outputDirectory, withIntermediateDirectories: true)
    for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
        guard let data = render(scale: scale) else {
            FileHandle.standardError.write(Data("make-dmg-background: render failed\n".utf8))
            exit(1)
        }
        try data.write(to: outputDirectory.appending(path: name))
    }
} catch {
    FileHandle.standardError.write(
        Data("make-dmg-background: \(error.localizedDescription)\n".utf8))
    exit(1)
}
