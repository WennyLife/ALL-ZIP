import Foundation

// Remove only the single outer wrapper, retaining all meaningful inner structure.
// The final path is new; FileManager.moveItem refuses to overwrite an existing path.
func publishExtraction(stage: URL, final: URL) throws {
 let fm = FileManager.default
 let children = try fm.contentsOfDirectory(at: stage,
     includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
 var payload = stage
 if children.count == 1 {
  let child = children[0]
  let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
  if values.isDirectory == true && values.isSymbolicLink != true {
   payload = child
  }
 }
 try fm.moveItem(at: payload, to: final)
 if payload != stage {
  // At this point publication succeeded; failure to remove an empty wrapper
  // must not report that the user's successfully extracted files were lost.
  try? fm.removeItem(at: stage)
 }
}
