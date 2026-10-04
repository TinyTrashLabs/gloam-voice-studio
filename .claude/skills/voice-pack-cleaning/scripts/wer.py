#!/usr/bin/env python3
"""Score a `spike qwen-ane-stress` run: transcribe every render (Studio MCP `transcribe`) and report
word error rate per part. usage: wer.py RUN_DIR [--language es-US] [--studio http://127.0.0.1:8790]
A render is "bad" when over 30% of its words are wrong (it said one word, or nothing, then silence)."""
import json,sys,base64,urllib.request,re,unicodedata,statistics,argparse
ap=argparse.ArgumentParser(); ap.add_argument("run"); ap.add_argument("--language",default="es-US"); ap.add_argument("--studio",default="http://127.0.0.1:8790")
a=ap.parse_args()
def norm(t):
    t=unicodedata.normalize("NFD",t.lower()); t="".join(c for c in t if unicodedata.category(c)!="Mn")
    return re.findall(r"[a-zñ0-9]+",t)
def wer(r,h):
    d=list(range(len(h)+1))
    for i,x in enumerate(r,1):
        p,d[0]=d[0],i
        for j,y in enumerate(h,1): p,d[j]=d[j],min(d[j]+1,d[j-1]+1,p+(x!=y))
    return d[-1]/max(1,len(r))
def transcribe(path):
    body={"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"transcribe","arguments":{"audio":base64.b64encode(open(path,"rb").read()).decode(),"language":a.language}}}
    r=json.loads(urllib.request.urlopen(urllib.request.Request(a.studio+"/mcp",data=json.dumps(body).encode(),headers={"Content-Type":"application/json","Accept":"application/json"}),timeout=300).read())
    return r["result"]["content"][0]["text"]
rows=[]
for l in open(f"{a.run}/renders.jsonl"):
    r=json.loads(l); r["heard"]=transcribe(f"{a.run}/{r['wav']}"); r["wer"]=wer(norm(r["text"]),norm(r["heard"])); rows.append(r)
json.dump(rows,open(f"{a.run}/scored.json","w"),ensure_ascii=False)
for p in sorted({r["part"] for r in rows}):
    w=[r["wer"] for r in rows if r["part"]==p]; bad=[r for r in rows if r["part"]==p and r["wer"]>0.3]
    print(f"part {p}: n={len(w)} median WER={statistics.median(w):.2f} bad(>30%)={len(bad)} worst={max(w):.2f}")
    for b in bad[:3]: print("   ",round(b["wer"],2),b["stop"],"|",b["heard"][:110])
