from pathlib import Path
import tempfile,subprocess,zipfile,os,json
engine=Path(__file__).with_name('JuntaZIPEngine').resolve()
tests=[]
def check(name,value):
 assert value,name
 tests.append(name)
with tempfile.TemporaryDirectory(prefix='ALLZIP-compress-test-') as t:
 root=Path(t);source=root/'Pasta';source.mkdir();(source/'Texturas').mkdir();payload=os.urandom(1024*1024)
 (source/'área.bin').write_bytes(payload);(source/'.oculto').write_text('oculto');(source/'Texturas/a.txt').write_text('textura')
 output=root/'saida.zip'
 scan=subprocess.run([str(engine),'cscan',str(output),'fast',str(source)],capture_output=True,text=True)
 check('Pré-leitura e bytes de origem',scan.returncode==0 and f'TOTAL\t{len(payload)+13}' in scan.stdout)
 run=subprocess.run([str(engine),'compress',str(output),'fast',str(source)],capture_output=True,text=True)
 check('ZIP criado com progresso',run.returncode==0 and 'PROGRESS\t' in run.stdout)
 with zipfile.ZipFile(output) as z:
  check('Integridade de todos os arquivos',z.testzip() is None and z.read('Pasta/área.bin')==payload)
  check('Subpastas e arquivos ocultos',z.read('Pasta/.oculto')==b'oculto' and z.read('Pasta/Texturas/a.txt')==b'textura')
  check('DEFLATE rápido e compatível',z.getinfo('Pasta/área.bin').compress_type==zipfile.ZIP_DEFLATED)
 before=output.read_bytes();run=subprocess.run([str(engine),'compress',str(output),'fast',str(source)],capture_output=True)
 check('Não substitui ZIP existente',run.returncode!=0 and output.read_bytes()==before)
 (source/'link').symlink_to(root)
 check('Links de origem bloqueados',subprocess.run([str(engine),'cscan',str(output),'fast',str(source)],capture_output=True).returncode!=0)
 (source/'link').unlink()
 # Output inside input must never recursively include its own ZIP.
 nested=source/'.temporario.zip';run=subprocess.run([str(engine),'compress',str(nested),'fast',str(source)],capture_output=True)
 with zipfile.ZipFile(nested) as z:check('ZIP temporário não entra no próprio conteúdo',run.returncode==0 and 'Pasta/.temporario.zip' not in z.namelist())
print(json.dumps({'compactacao':'aprovada','testes':tests},ensure_ascii=False,indent=2))
