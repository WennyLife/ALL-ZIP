from pathlib import Path
import subprocess,plistlib,shutil,tempfile
ROOT=Path(__file__).resolve().parent
APP=Path(tempfile.mkdtemp(prefix='JuntaZIP-build-'))/'ALL ZIP.app'
CONTENTS=APP/'Contents'
(CONTENTS/'MacOS').mkdir(parents=True,exist_ok=True)
(CONTENTS/'Resources').mkdir(exist_ok=True)
subprocess.run(['clang','-O3','-Wall','-Wextra',str(ROOT/'Engine.c'),str(ROOT/'Compress.c'),'-larchive','-o',str(CONTENTS/'MacOS'/'JuntaZIPEngine')],check=True)
subprocess.run(['swiftc','-O','-swift-version','5',str(ROOT/'Main.swift'),str(ROOT/'Publication.swift'),str(ROOT/'Compression.swift'),str(ROOT/'GoogleAuth.swift'),str(ROOT/'DownloadTransfer.swift'),str(ROOT/'Drive.swift'),str(ROOT/'Views.swift'),str(ROOT/'ShimmerProgress.swift'),'-o',str(CONTENTS/'MacOS'/'JuntaZIP'),'-framework','AppKit','-framework','SwiftUI','-framework','UniformTypeIdentifiers','-framework','Security'],check=True)
shutil.copy2(CONTENTS/'MacOS'/'JuntaZIPEngine',ROOT/'JuntaZIPEngine')
info={
 'CFBundleIdentifier':'com.lendaii.juntazip','CFBundleName':'ALL ZIP','CFBundleDisplayName':'ALL ZIP',
 'CFBundleExecutable':'JuntaZIP','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.1.6','CFBundleVersion':'10',
 'LSMinimumSystemVersion':'26.0','NSHighResolutionCapable':True,'CFBundleIconFile':'JuntaZIP',
 'CFBundleDocumentTypes':[{'CFBundleTypeName':'Arquivos ZIP','CFBundleTypeRole':'Viewer','LSHandlerRank':'Alternate','LSItemContentTypes':['public.zip-archive','com.pkware.zip-archive']}],
 'NSServices':[{'NSMenuItem':{'default':'Extrair juntos com ALL ZIP'},'NSMessage':'extractTogether','NSPortName':'ALL ZIP','NSSendTypes':['NSFilenamesPboardType','public.file-url'],'NSRequiredContext':{'NSTextContent':'FilePath'}}]
}
(CONTENTS/'Info.plist').write_bytes(plistlib.dumps(info))
shutil.copyfile(ROOT/'JuntaZIP.icns',CONTENTS/'Resources'/'JuntaZIP.icns')
if (ROOT/'GoogleOAuthClient.json').exists(): shutil.copyfile(ROOT/'GoogleOAuthClient.json',CONTENTS/'Resources'/'GoogleOAuthClient.json')
subprocess.run(['xattr','-cr',str(APP)],check=True)
subprocess.run(['codesign','--force','--sign','-',str(CONTENTS/'MacOS'/'JuntaZIPEngine')],check=True)
subprocess.run(['codesign','--force','--sign','-',str(APP)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(APP)],check=True)
(ROOT/'build-location.txt').write_text(str(APP))
print(APP)
