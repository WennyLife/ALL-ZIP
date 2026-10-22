import AppKit
let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
 for scale in [1,2] {
  let pixels=size*scale
  let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  let context=NSGraphicsContext(bitmapImageRep:bitmap)!
  NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
  let p=CGFloat(pixels)
  let background=NSBezierPath(roundedRect:NSRect(x:p*0.06,y:p*0.06,width:p*0.88,height:p*0.88),xRadius:p*0.2,yRadius:p*0.2)
  NSColor(calibratedRed:0.12,green:0.48,blue:0.92,alpha:1).setFill();background.fill()
  if let symbol=NSImage(systemSymbolName:"doc.zipper",accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:p*0.53,weight:.regular)) {
   let tinted=NSImage(size:symbol.size);tinted.lockFocus();symbol.draw(at:.zero,from:.zero,operation:.sourceOver,fraction:1);NSColor.white.setFill();NSRect(origin:.zero,size:symbol.size).fill(using:.sourceAtop);tinted.unlockFocus()
   tinted.draw(in:NSRect(x:p*0.265,y:p*0.21,width:p*0.47,height:p*0.58))
  }
  NSGraphicsContext.restoreGraphicsState()
  let filename="icon_\(size)x\(size)\(scale==2 ? "@2x":"").png"
  try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(filename))
 }
}
