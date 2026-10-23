#!/usr/bin/env swift
// Tile screenshots into one labeled grid (row-major), each scaled to
// <cellWidth> px, for reviewing scripts/mac-screenshots.sh output a page at
// a time instead of image by image:
//
//   swift scripts/contact-sheet.swift <out.png> <columns> <cellWidth> <png>...
//   e.g. one route, sizes down, light | dark across:
//   swift scripts/contact-sheet.swift person.png 2 1000 \
//       $(for z in 900x600 1280x800 1512x982 1920x1080 2560x1440; do
//           echo shots/person-$z-light.png shots/person-$z-dark.png; done)
import AppKit
let a = CommandLine.arguments
guard a.count > 4, let cols = Int(a[2]), let cellW = Double(a[3]) else {
    print("usage: contact-sheet.swift <out.png> <columns> <cellWidth> <png>..."); exit(64)
}
let paths = Array(a.dropFirst(4))
let images = paths.map { NSImage(contentsOfFile: $0) }
let label = 34.0, pad = 12.0
func cellH(_ img: NSImage?) -> Double {
    guard let r = img?.representations.first else { return 100 }
    return cellW * Double(r.pixelsHigh) / Double(r.pixelsWide)
}
let rows = (paths.count + cols - 1) / cols
var rowH: [Double] = []
for r in 0..<rows {
    rowH.append((0..<cols).map { r * cols + $0 }.filter { $0 < paths.count }.map { cellH(images[$0]) }.max()! + label + pad)
}
let W = Double(cols) * (cellW + pad) + pad, H = rowH.reduce(0, +) + pad
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(calibratedRed: 1, green: 0.85, blue: 0.4, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()
var y = H
for r in 0..<rows {
    y -= rowH[r]
    for c in 0..<cols {
        let i = r * cols + c; guard i < paths.count else { continue }
        let x = pad + Double(c) * (cellW + pad)
        let h = cellH(images[i])
        let name = (paths[i] as NSString).lastPathComponent
        (name as NSString).draw(at: NSPoint(x: x, y: y + rowH[r] - label + 4),
            withAttributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.black])
        let rect = NSRect(x: x, y: y + rowH[r] - label - h, width: cellW, height: h)
        NSColor.black.setFill(); rect.insetBy(dx: -2, dy: -2).fill()
        images[i]?.draw(in: rect)
    }
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
print("wrote \(a[1]) \(Int(W))x\(Int(H))")
