"""USB-pair the existing Sage iPhone app without putting credentials in the build."""
import argparse, json, os, pathlib, subprocess, tempfile
parser=argparse.ArgumentParser()
parser.add_argument('--device',required=True)
parser.add_argument('--url',required=True,help='Reachable Mac API URL, e.g. http://YOUR_MAC.local:8789')
args=parser.parse_args()
root=pathlib.Path(__file__).resolve().parents[1]
config=dict(line.split('=',1) for line in (root/'backend/.env').read_text().splitlines() if '=' in line)
with tempfile.TemporaryDirectory(prefix='sage-pair-') as temporary:
    path=pathlib.Path(temporary)/'mac-backend.json'
    descriptor=os.open(path,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
    with os.fdopen(descriptor,'w') as stream:json.dump({'url':args.url,'token':config['SAGE_TOKEN']},stream)
    subprocess.run(['xcrun','devicectl','device','copy','to','--device',args.device,
        '--domain-type','appDataContainer','--domain-identifier','app.veea.veeaSage',
        '--source',str(path),'--destination','Library/Application Support/mac-backend.json'],check=True)
print('Pairing file transferred. Open Sage to import into Keychain and enable Mac processing.')
