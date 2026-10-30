from pathlib import Path
import tempfile, subprocess, sys

src = Path(__file__).resolve().parent

with tempfile.TemporaryDirectory(prefix='ALLZIP-accounts-test-') as temp:
    root = Path(temp)
    main_swift = root / 'main.swift'
    main_swift.write_text((src / 'test_accounts.swift').read_text())
    
    cmd = [
        'swiftc',
        '-swift-version', '5',
        str(src / 'GoogleAuth.swift'),
        str(src / 'DownloadTransfer.swift'),
        str(src / 'Drive.swift'),
        str(main_swift),
        '-framework', 'AppKit',
        '-framework', 'Security',
        '-o', str(root / 'test_accounts')
    ]
    
    print("Compilando suíte de testes de contas e autorização...")
    subprocess.run(cmd, check=True)
    
    print("Executando testes comportamentais isolados...")
    res = subprocess.run([str(root / 'test_accounts')])
    if res.returncode != 0:
        sys.exit(res.returncode)
