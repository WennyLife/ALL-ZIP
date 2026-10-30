from pathlib import Path
import tempfile,subprocess,shutil,plistlib,zipfile
src=Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='ALLZIP-destination-') as temp:
 root=Path(temp);app=root/'DestinationTest.app';mac=app/'Contents/MacOS';mac.mkdir(parents=True)
 (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'test.allzip.destination','CFBundleExecutable':'test','CFBundlePackageType':'APPL'}))
 (root/'Model.swift').write_text((src/'Main.swift').read_text().split('final class Delegate:')[0])
 shutil.copy2(src/'JuntaZIPEngine',mac/'JuntaZIPEngine')
 for folder in ['origem A','origem B','manual']:(root/folder).mkdir()
 for name,folder in [('primeiro.zip','origem A'),('segundo.zip','origem B')]:
  with zipfile.ZipFile(root/folder/name,'w') as z:z.writestr('arquivo.txt','destino correto')
 (root/'main.swift').write_text(r'''
import Foundation
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let a=root.appendingPathComponent("origem A/primeiro.zip"), b=root.appendingPathComponent("origem B/segundo.zip"), manual=root.appendingPathComponent("manual")
let model=Model();model.sounds=false;model.paneMode=0
let downloads=model.driveDestination
model.add([a]);assert(model.destination==a.deletingLastPathComponent());assert(model.driveDestination==downloads)
model.beginOperation()
func wait(_ model:Model){let end=Date().addingTimeInterval(10);while model.busy && Date()<end{RunLoop.main.run(until:Date().addingTimeInterval(0.01))};assert(!model.busy);assert(model.result != nil,model.status)}
wait(model);assert(model.result!.deletingLastPathComponent()==a.deletingLastPathComponent());assert(try! String(contentsOf:model.result!.appendingPathComponent("arquivo.txt"),encoding:.utf8)=="destino correto")
model.add([b]);assert(model.files==[b]);assert(model.destination==b.deletingLastPathComponent())
model.setDestination(manual);model.add([b]);assert(model.destination==manual)
model.beginOperation();wait(model);assert(model.result!.deletingLastPathComponent()==manual)
model.add([a]);assert(model.destination==a.deletingLastPathComponent());assert(model.files==[a])
let explicit=Model();explicit.paneMode=0;explicit.setDestination(manual);explicit.add([a]);assert(explicit.destination==manual)
let drive=Model();drive.setDestination(manual);assert(drive.driveDestination==manual);drive.paneMode=0;drive.add([b]);assert(drive.destination==b.deletingLastPathComponent());assert(drive.driveDestination==manual)
let pending=Model();pending.paneMode=0;pending.add([a]);pending.busy=true;pending.add([b]);assert(pending.destination==a.deletingLastPathComponent());pending.finish();assert(pending.destination==b.deletingLastPathComponent());assert(pending.files==[b])
print("APROVADO: extração real na origem, Alterar manual, próxima seleção, pendentes e Drive independente")
''')
 subprocess.run(['swiftc','-swift-version','5',str(root/'Model.swift'),str(src/'Publication.swift'),str(src/'Compression.swift'),str(root/'main.swift'),'-framework','AppKit','-framework','SwiftUI','-framework','UniformTypeIdentifiers','-o',str(mac/'test')],check=True)
 subprocess.run([str(mac/'test'),str(root)],check=True)
