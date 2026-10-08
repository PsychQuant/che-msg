import json, sys, yaml, collections
sys.path.insert(0, sys.argv[3]); from frontmatter_subset import subset_problems
blocks=[json.loads(l) for l in open(sys.argv[1])]; buns=[json.loads(l) for l in open(sys.argv[2])]
c=collections.Counter(); ex=collections.defaultdict(list)
def cmp(a,b,path=""):
    if isinstance(a,dict) and isinstance(b,dict):
        if set(map(str,a))!=set(map(str,b)): return "struct"
        for k in a:
            r=cmp(a[k],b[str(k)]); 
            if r: return r
        return None
    if isinstance(a,list) and isinstance(b,list):
        if len(a)!=len(b): return "struct"
        for x,y in zip(a,b):
            r=cmp(x,y)
            if r: return r
        return None
    if isinstance(a,(dict,list)) or isinstance(b,(dict,list)): return "struct"
    if isinstance(a,str) and isinstance(b,str): return None if a==b else "string"
    if type(a)==type(b) or (isinstance(a,(int,float)) and isinstance(b,(int,float)) and not isinstance(a,bool) and not isinstance(b,bool)): return None if a==b else "value"
    return "typing"
for blk,bun in zip(blocks,buns):
    if subset_problems(blk): c["rejected"]+=1; continue
    c["accepted"]+=1
    if not bun["ok"]: c["BUN_FAIL"]+=1; ex["BUN_FAIL"].append(blk); continue
    try: py=yaml.safe_load(blk)
    except Exception: c["pyyaml_fail(test fails closed)"]+=1; ex["py"].append(blk); continue
    r=cmp(py if py is not None else {}, bun["v"] if bun["v"] is not None else {})
    if r: c[r.upper() if r!="typing" else "typing(exact-string checks unaffected)"]+=1; ex[r].append((blk,py,bun["v"]))
    else: c["agree"]+=1
print(dict(c))
for k in ("BUN_FAIL","struct","string","value"):
    for e in ex[k][:3]: print(k, repr(e)[:300])
print("pyyaml_fail examples:", [repr(b)[:120] for b in ex["py"][:3]])
