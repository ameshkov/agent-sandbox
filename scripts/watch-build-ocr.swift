// watch-build-ocr.swift — OCR helper for the Windows sandbox build watchdog.
//
// Compiled on first use by scripts/watch-build.sh (swiftc -O) into the
// watchdog outdir; the Python worker (scripts/watch-build.py) runs it on
// each captured VNC frame. Uses Apple's Vision framework — no external OCR
// dependency, and the Xcode command line tools are already a build
// prerequisite on the host.
//
// Prints one line per recognized text:
//   <text> | center=(<x>,<y>) box=(<x>,<y> <w>x<h>)
// with pixel coordinates in the image's own resolution (top-left origin),
// so the worker can click OCR'd buttons without assuming a framebuffer
// size.

import Vision
import AppKit

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let img = NSImage(contentsOf: url),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot load image\n".data(using: .utf8)!)
    exit(1)
}
let w = cg.width
let h = cg.height
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(cgImage: cg, options: [:])
try handler.perform([request])
for obs in request.results ?? [] {
    if let c = obs.topCandidates(1).first {
        let bb = obs.boundingBox  // normalized, origin bottom-left
        let x = Int(bb.origin.x * CGFloat(w))
        let y = Int((1 - bb.origin.y - bb.size.height) * CGFloat(h))
        let bw = Int(bb.size.width * CGFloat(w))
        let bh = Int(bb.size.height * CGFloat(h))
        print("\(c.string) | center=(\(x + bw/2),\(y + bh/2)) box=(\(x),\(y) \(bw)x\(bh))")
    }
}
