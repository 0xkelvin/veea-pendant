"""Local integration test using the bundled public speech sample; never logs tokens."""
import argparse, json, time, urllib.request, pathlib
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--url', required=True, help='Mac API URL, e.g. http://YOUR_MAC.local:8789')
parser.add_argument('--sample', type=pathlib.Path, default=pathlib.Path('/opt/homebrew/share/whisper-cpp/jfk.wav'), help='Path to the public whisper.cpp JFK WAV sample')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
config = dict(line.split('=',1) for line in (root/'backend/.env').read_text().splitlines() if '=' in line)
base = args.url.rstrip('/')
def request(path, data=None, content='application/json'):
    req=urllib.request.Request(base+path,data=data,headers={'Authorization':'Bearer '+config['SAGE_TOKEN'],'Content-Type':content})
    with urllib.request.urlopen(req,timeout=150) as response:return json.load(response)
print('Capabilities:',request('/v1/inference'))
audio=args.sample.read_bytes()
path='/v1/transcriptions?model=mac-whisper-large-v3&language=en&quietSpeech=false'
job=request(path,audio,'audio/wav')['id']
assert request(path,audio,'audio/wav')['id']==job
print('Duplicate submission reuses the same job.')
for attempt in range(60):
    result=request('/v1/transcriptions/'+job)
    if result['status']=='complete':break
    if result['status']=='failed':raise RuntimeError('Transcription worker failed')
    time.sleep(1)
else:raise RuntimeError('Transcription timed out')
run=result['run'];assert 'country' in run['text'].lower();assert run['segments'];assert run['model']=='mac-whisper-large-v3'
print('Speech sample: %.2fs audio, %.2fs inference, %d segments' % (run['audioStats']['duration'],run['seconds'],len(run['segments'])))
topics=request('/v1/topics',json.dumps({'text':'Tôi chưa gửi firmware. Mai tôi sẽ kiểm tra BLE reconnect.'}).encode())
assert topics['topics'];print('Vietnamese topic extraction passed (%d evidence-backed topics).' % len(topics['topics']))
print('Local end-to-end integration passed.')
