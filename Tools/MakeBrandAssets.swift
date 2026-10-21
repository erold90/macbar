// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacBar contributors
//
// Draws MacBar's own artwork (Resources/Brand/logo.png and AppIcon-Default.png).
// The upstream project's name, logo and icon are not reused: see NOTICE.md.
// Run: swift Tools/MakeBrandAssets.swift
import AppKit

func canvas(_ px: Int, _ pyh: Int) -> (NSBitmapImageRep, NSGraphicsContext) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: pyh,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: pyh)
    return (rep, NSGraphicsContext(bitmapImageRep: rep)!)
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// A capsule "bar" holding three dots; the first dot is filled, the others hollow.
func drawBar(in rect: CGRect, stroke: NSColor, fill: NSColor, line: CGFloat) {
    let r = rect.height / 2
    let bar = NSBezierPath(roundedRect: rect.insetBy(dx: line / 2, dy: line / 2),
                           xRadius: r, yRadius: r)
    bar.lineWidth = line
    stroke.setStroke()
    bar.stroke()
    let d = rect.height * 0.34
    let gap = rect.height * 0.34
    let total = d * 3 + gap * 2
    var x = rect.midX - total / 2
    for i in 0..<3 {
        let dot = NSBezierPath(ovalIn: CGRect(x: x, y: rect.midY - d / 2, width: d, height: d))
        if i == 0 { fill.setFill(); dot.fill() } else { dot.lineWidth = line * 0.8; fill.setStroke(); dot.stroke() }
        x += d + gap
    }
}

let root = FileManager.default.currentDirectoryPath

// 1) Wordmark master: black bar glyph on transparent (used as a template image).
do {
    let (rep, ctx) = canvas(1200, 600)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    // Aspect ~1.9:1 keeps the glyph inside the 26x20 pt menu bar canvas without touching its edges.
    drawBar(in: CGRect(x: 220, y: 100, width: 760, height: 400), stroke: .black, fill: .black, line: 40)
    NSGraphicsContext.restoreGraphicsState()
    write(rep, to: "\(root)/Resources/Brand/logo.png")
}

// 2) App icon: 824pt squircle on a 1024 canvas, blue gradient, white bar glyph.
do {
    let (rep, ctx) = canvas(1024, 1024)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -12)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    NSBezierPath(roundedRect: body, xRadius: 184, yRadius: 184).fill()
    NSGraphicsContext.restoreGraphicsState()
    let clip = NSBezierPath(roundedRect: body, xRadius: 184, yRadius: 184)
    clip.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.62, blue: 0.98, alpha: 1),
                        NSColor(srgbRed: 0.31, green: 0.28, blue: 0.86, alpha: 1)])!
        .draw(in: body, angle: -60)
    drawBar(in: CGRect(x: 232, y: 392, width: 560, height: 240), stroke: .white, fill: .white, line: 30)
    NSGraphicsContext.restoreGraphicsState()
    write(rep, to: "\(root)/Resources/Brand/AppIcon-Default.png")
}
print("ok")
