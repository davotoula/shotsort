// Regenerate committed fixtures:
//   swift fixtures/synthetic/make_fixtures.swift
//
// Fixtures are synthetic by policy. The collection this tool sorts is private
// enough that the design forbids network calls; committing real screenshots
// to a git repository would undo that in the most durable way available.
import AppKit
import Foundation

func render(text: String, to url: URL,
            size: NSSize = NSSize(width: 600, height: 400)) {
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 36),
        .foregroundColor: NSColor.black,
    ]
    NSAttributedString(string: text, attributes: attrs)
        .draw(at: NSPoint(x: 40, y: size.height / 2))
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

let dir = URL(fileURLWithPath: "fixtures/synthetic")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
render(text: "HELLO SHOTSORT",
       to: dir.appendingPathComponent("Screenshot_20260101-120000.png"))
render(text: "news.sky.com",
       to: dir.appendingPathComponent("Screenshot_20260102-130000.png"))
render(text: "",
       to: dir.appendingPathComponent("Screenshot_20260103-140000.png"))
print("wrote 3 fixtures")
