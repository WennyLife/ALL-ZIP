from pathlib import Path
import subprocess, tempfile, zipfile, stat, hashlib, time, json, os

ENGINE=Path(__file__).with_name('JuntaZIPEngine').resolve()
results=[]
def run(mode,dest,archives,policy='both'):
    return subprocess.run([str(ENGINE),mode,str(dest),policy,*map(str,archives)],capture_output=True,text=True)
def check(name,condition):
    assert condition,name
    results.append({'teste':name,'resultado':'aprovado'})
def make(path,entries):
    with zipfile.ZipFile(path,'w',compression=zipfile.ZIP_DEFLATED) as z:
        for k,v in entries: z.writestr(k,v)

with tempfile.TemporaryDirectory(prefix='JuntaZIP-tests-') as temp:
    root=Path(temp);dest=root/'out';dest.mkdir()
    a=root/'001.zip';b=root/'002.zip'
    make(a,[('Jogo/',''),('Jogo/texturas/área.txt','original'),('Jogo/data.bin',b'abc'*10000)])
    make(b,[('Jogo/texturas/nova.txt','novo'),('Jogo/texturas/área.txt','segundo')])
    r=run('scan',dest,[a,b]);check('Pré-leitura dos ZIPs',r.returncode==0 and 'TOTAL\t' in r.stdout)
    r=run('extract',dest,[a,b]);check('Unificação de subpastas',r.returncode==0 and (dest/'Jogo/texturas/nova.txt').read_text()=='novo')
    check('Nomes repetidos e Unicode', (dest/'Jogo/texturas/área.txt').read_text()=='original' and (dest/'Jogo/texturas/área (2).txt').read_text()=='segundo')
    check('Conteúdo íntegro',(dest/'Jogo/data.bin').read_bytes()==b'abc'*10000)
    check('Bytes de progresso reais','PROGRESS\t30019' in r.stdout)
    check('ZIPs originais preservados',a.exists() and b.exists())
    skip=root/'skip';skip.mkdir();r=run('extract',skip,[a,b],'skip');check('Preservar primeiro',r.returncode==0 and not (skip/'Jogo/texturas/área (2).txt').exists())
    for name,path in [('Traversal','../escape.txt'),('Absoluto','/tmp/escape.txt'),('Barra invertida','..\\escape.txt')]:
        bad=root/(name+'.zip');make(bad,[(path,'malicioso')]);r=run('scan',dest,[bad]);check('Bloqueio: '+name,r.returncode!=0 and not (root/'escape.txt').exists())
    bad=root/'link.zip'
    with zipfile.ZipFile(bad,'w') as z:
        entry=zipfile.ZipInfo('link');entry.create_system=3;entry.external_attr=(stat.S_IFLNK|0o777)<<16;z.writestr(entry,'/tmp')
    check('Bloqueio de links',run('scan',dest,[bad]).returncode!=0)
    poison=root/'poison';poison.mkdir();(poison/'Jogo').symlink_to(root,target_is_directory=True)
    check('Destino com link bloqueado',run('extract',poison,[a]).returncode!=0 and not (root/'data.bin').exists())
    corrupt=root/'crc.zip'
    with zipfile.ZipFile(corrupt,'w',compression=zipfile.ZIP_STORED) as z:z.writestr('payload.txt',b'payload original')
    raw=corrupt.read_bytes().replace(b'payload original',b'payload alterado');corrupt.write_bytes(raw)
    crc=root/'crc';crc.mkdir();check('Erro de CRC detectado',run('extract',crc,[corrupt]).returncode!=0)
    truncated=root/'truncated.zip';truncated.write_bytes(a.read_bytes()[:35]);check('ZIP truncado rejeitado',run('extract',dest,[truncated]).returncode!=0)
    # Controlled throughput sample. Repeated data favors caches; no claims about real user ZIPs.
    bench=root/'bench.zip';payload=os.urandom(1024*1024)*128
    make(bench,[('benchmark.bin',payload)]);benchout=root/'benchout';benchout.mkdir()
    start=time.monotonic();r=run('extract',benchout,[bench]);elapsed=time.monotonic()-start
    check('Benchmark com SHA-256',r.returncode==0 and hashlib.sha256((benchout/'benchmark.bin').read_bytes()).digest()==hashlib.sha256(payload).digest())
    results.append({'benchmark':'ZIP sintético de 128 MiB, cache local possível','segundos':round(elapsed,3),'MB_s':round(len(payload)/elapsed/1e6,1)})
print(json.dumps(results,ensure_ascii=False,indent=2))
