#!/usr/bin/env python3
"""Prepare a candidate reference's Qwen (ANE) files through the running Studio: creates a temporary voice
from the clip + its exact transcript, renders one line so Studio preps it, exports, and writes
OUT_DIR/{ref_codes.npy,spk_embed.npy,voice.json} (the voice dir `spike qwen-ane-stress --voice` takes).
usage: qwen-files.py CLIP.wav TRANSCRIPT.txt OUT_DIR [--language es] [--studio URL]
The clip must be 24 kHz mono 16-bit (afconvert -f WAVE -d LEI16@24000 -c 1 in.wav out.wav)."""
import base64,json,urllib.request,zipfile,io,os,struct,argparse,uuid
ap=argparse.ArgumentParser(); ap.add_argument("clip"); ap.add_argument("text"); ap.add_argument("out"); ap.add_argument("--language",default="es"); ap.add_argument("--studio",default="http://127.0.0.1:8790")
a=ap.parse_args()
def req(path,b=None,m="POST",raw=False):
    r=urllib.request.urlopen(urllib.request.Request(a.studio+path,data=None if b is None else json.dumps(b).encode(),method=m,headers={"Content-Type":"application/json"}),timeout=900).read()
    return r if raw else json.loads(r)
text=open(a.text).read().strip(); slug="packclean-"+uuid.uuid4().hex[:6]
meta=req("/voices",{"name":slug,"refAudio":base64.b64encode(open(a.clip,"rb").read()).decode(),"refText":text})
try:
    req("/v1/audio/speech",{"model":"qwen3-0.6b-ane","voice":meta["slug"],"language":a.language,"input":"Hola.","response_format":"wav"},raw=True)
    z=zipfile.ZipFile(io.BytesIO(req(f"/voices/{meta['slug']}/export",m="GET",raw=True)))
    os.makedirs(a.out,exist_ok=True)
    for f in ("ref_codes.npy","spk_embed.npy"): open(f"{a.out}/{f}","wb").write(z.read(f"engines/qwen3-0.6b/{f}"))
    v=json.loads(z.read("engines/qwen3-0.6b/voice.json")); rt=v.get("text") or v.get("ref_text")
    raw=z.read("engines/qwen3-0.6b/ref_codes.npy"); hl=struct.unpack('<H',raw[8:10])[0]
    T=int(raw[10:10+hl].decode().split("shape")[1].split("(")[1].split(")")[0].split(",")[2])
    json.dump({"ref_text":rt,"frames":T,"language":a.language,"mel":"upstream","prep_version":1},open(f"{a.out}/voice.json","w"),ensure_ascii=False)
    print(a.out,"frames",T,"(must be <= 256) | ends:",rt[-50:])
finally:
    req(f"/voices/{meta['slug']}",m="DELETE")
