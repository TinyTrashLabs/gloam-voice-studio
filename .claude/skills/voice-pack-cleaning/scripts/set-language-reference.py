#!/usr/bin/env python3
"""Swap one language reference inside a .gvoice pack (Benson layout) and bump the pack revision.
usage: set-language-reference.py PACK.gvoice LANG CLIP.wav TRANSCRIPT.txt QWEN_DIR OUT.gvoice
QWEN_DIR holds ref_codes.npy + spk_embed.npy for CLIP (from qwen-files.py). Writes source/ref-LANG.wav,
engines/qwen3-0.6b/{ref-LANG.wav,ref_codes-LANG.npy,spk_embed-LANG.npy,voice-LANG.json} and the
manifest's source.LANG text; everything else in the pack is kept byte for byte."""
import zipfile,json,sys,hashlib
pack,lang,clip,txt,qdir,out=sys.argv[1:7]
z=zipfile.ZipFile(pack); files={n:z.read(n) for n in z.namelist()}; z.close()
m=json.loads(files["manifest.json"]); text=open(txt).read().strip(); wav=open(clip,"rb").read()
e="engines/qwen3-0.6b/"
v=json.loads(files.get(f"{e}voice-{lang}.json",b'{}') or b'{}')
v.update({"refCodes":f"{e}ref_codes-{lang}.npy","spkEmbedding":f"{e}spk_embed-{lang}.npy","text":text,
          "derivedFrom":{**v.get("derivedFrom",{"by":"QwenVoicePrep","mel":"upstream","prepVersion":1}),"audio":f"source/ref-{lang}.wav","sha256":hashlib.sha256(wav).hexdigest()}})
files[f"{e}voice-{lang}.json"]=json.dumps(v,ensure_ascii=False,indent=1).encode()
files[f"{e}ref_codes-{lang}.npy"]=open(f"{qdir}/ref_codes.npy","rb").read()
files[f"{e}spk_embed-{lang}.npy"]=open(f"{qdir}/spk_embed.npy","rb").read()
files[f"{e}ref-{lang}.wav"]=wav; files[f"source/ref-{lang}.wav"]=wav
m.setdefault("source",{}).setdefault(lang,{"audio":f"source/ref-{lang}.wav","language":lang})["text"]=text
m["source"][lang]["audio"]=f"source/ref-{lang}.wav"
if lang not in m.get("variants",[]): m.setdefault("variants",["base"]).append(lang)
eng=m.setdefault("engines",{}).setdefault("qwen3-0.6b",{}); eng[lang]=[f"{e}ref_codes-{lang}.npy",f"{e}spk_embed-{lang}.npy",f"{e}voice-{lang}.json"]
m["revision"]=int(m.get("revision") or 1)+1
files["manifest.json"]=json.dumps(m,ensure_ascii=False).encode()
with zipfile.ZipFile(out,"w",zipfile.ZIP_DEFLATED) as o:
    for n,d in files.items(): o.writestr(n,d)
print(out,"revision",m["revision"])
