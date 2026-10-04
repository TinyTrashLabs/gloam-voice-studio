#!/usr/bin/env python3
"""Voice match (resemblyzer cosine, 1.0 = same voice) of candidate clips against reference recordings,
plus each candidate's transcript tail. Run with:
  uv run --python 3.11 --with resemblyzer --with "numpy<2" --with "setuptools<70" python similarity.py \
     --ref es=real-spanish.wav --ref en=real-english.wav cand1.wav cand2.wav ...
A take generated "from his Spanish" should match the Spanish ref clearly better than the English one."""
import argparse,numpy as np,base64,json,urllib.request
from resemblyzer import VoiceEncoder, preprocess_wav
ap=argparse.ArgumentParser(); ap.add_argument("--ref",action="append",required=True); ap.add_argument("--language",default="es-US"); ap.add_argument("--studio",default="http://127.0.0.1:8790"); ap.add_argument("files",nargs="+")
a=ap.parse_args(); enc=VoiceEncoder("cpu")
refs={k:enc.embed_utterance(preprocess_wav(v)) for k,v in (r.split("=",1) for r in a.ref)}
for f in a.files:
    e=enc.embed_utterance(preprocess_wav(f))
    body={"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"transcribe","arguments":{"audio":base64.b64encode(open(f,"rb").read()).decode(),"language":a.language}}}
    t=json.loads(urllib.request.urlopen(urllib.request.Request(a.studio+"/mcp",data=json.dumps(body).encode(),headers={"Content-Type":"application/json","Accept":"application/json"}),timeout=300).read())["result"]["content"][0]["text"]
    print(f, " ".join(f"sim_{k} {float(np.dot(e,v)):.3f}" for k,v in refs.items()), "|", t[-60:])
