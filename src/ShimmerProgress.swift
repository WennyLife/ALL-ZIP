import AppKit
import SwiftUI
import QuartzCore

struct ShimmerProgress:View {
 let value:Double
 let active:Bool
 @Environment(\.accessibilityReduceMotion) private var reduceMotion
 var body:some View {
  FilledProgress(value:value,animated:active && !reduceMotion)
   .frame(height:6)
 }
}
private struct FilledProgress:NSViewRepresentable {
 let value:Double
 let animated:Bool
 func makeNSView(context:Context)->FilledProgressView{FilledProgressView()}
 func updateNSView(_ view:FilledProgressView,context:Context){view.progress=value;view.animated=animated;view.refresh()}
 static func dismantleNSView(_ view:FilledProgressView,coordinator:()){view.stop()}
}
private final class FilledProgressView:NSView {
 private let track=CALayer()
 private let fill=CALayer()
 private let shine=CAGradientLayer()
 private var observedWindow:NSWindow?
 var progress:Double=0
 var animated=false
 override init(frame:NSRect){super.init(frame:frame);wantsLayer=true
  track.masksToBounds=true;track.cornerRadius=3;fill.masksToBounds=true;fill.cornerRadius=3
  layer?.addSublayer(track);track.addSublayer(fill);fill.addSublayer(shine)
  shine.colors=[NSColor.white.withAlphaComponent(0).cgColor,NSColor.white.withAlphaComponent(0.4).cgColor,NSColor.white.withAlphaComponent(0).cgColor]
  shine.locations=[0,0.5,1];shine.startPoint=CGPoint(x:0,y:0.5);shine.endPoint=CGPoint(x:1,y:0.5)
  setAccessibilityElement(true);setAccessibilityRole(.progressIndicator);setAccessibilityLabel("Progresso");setAccessibilityMinValue(0);setAccessibilityMaxValue(100)
 }
 required init?(coder:NSCoder){fatalError("init(coder:) not supported")}
 override func viewDidMoveToWindow(){super.viewDidMoveToWindow();if let old=observedWindow{NotificationCenter.default.removeObserver(self,name:NSWindow.didChangeOcclusionStateNotification,object:old)};observedWindow=window;if let window=window{NotificationCenter.default.addObserver(self,selector:#selector(refresh),name:NSWindow.didChangeOcclusionStateNotification,object:window)};refresh()}
 override func layout(){super.layout();refresh()}
 override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();refresh()}
 @objc func refresh(){
  let fraction=progress.isFinite ? min(1,max(0,progress)):0
  CATransaction.begin();CATransaction.setDisableActions(true)
  track.frame=bounds;fill.frame=CGRect(x:0,y:0,width:bounds.width*fraction,height:bounds.height);shine.frame=fill.bounds
  effectiveAppearance.performAsCurrentDrawingAppearance{track.backgroundColor=NSColor.quaternaryLabelColor.cgColor;fill.backgroundColor=NSColor.controlAccentColor.cgColor}
  CATransaction.commit();setAccessibilityValue(NSNumber(value:fraction*100))
  guard animated,fraction>0,fraction<1,bounds.width>0,let window=window,window.isVisible,window.occlusionState.contains(.visible) else{stop();return}
  shine.isHidden=false
  guard shine.animation(forKey:"shimmer")==nil else{return}
  // Animate normalized locations: resizing the filled segment never restarts the sweep.
  let animation=CABasicAnimation(keyPath:"locations");animation.fromValue=[NSNumber(value:-0.3),NSNumber(value:-0.15),NSNumber(value:0)];animation.toValue=[NSNumber(value:1),NSNumber(value:1.15),NSNumber(value:1.3)];animation.duration=2.2;animation.repeatCount = .infinity;animation.timingFunction=CAMediaTimingFunction(name:.linear);shine.add(animation,forKey:"shimmer")
 }
 func stop(){shine.removeAnimation(forKey:"shimmer");shine.isHidden=true}
 deinit{NotificationCenter.default.removeObserver(self)}
}
