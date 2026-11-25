import unicodedata as u
C="L R AL EN ES ET AN CS NSM BN B S WS ON LRE RLE LRO RLO PDF LRI RLI FSI PDI".split()
def cls(c):
    b=u.bidirectional(chr(c))
    if b: return b
    if 0x590<=c<=0x5FF or 0x7C0<=c<=0x85F or 0xFB1D<=c<=0xFB4F or 0x10800<=c<=0x10CFF or 0x10D40<=c<=0x10EBF or 0x10F00<=c<=0x10F2F or 0x10F70<=c<=0x10FFF or 0x1E800<=c<=0x1EC6F or 0x1ECC0<=c<=0x1ECFF or 0x1ED50<=c<=0x1EDFF or 0x1EF00<=c<=0x1EFFF: return "R"
    if 0x600<=c<=0x7BF or 0x860<=c<=0x8FF or 0xFB50<=c<=0xFDCF or 0xFDF0<=c<=0xFDFF or 0xFE70<=c<=0xFEFF or 0x10D00<=c<=0x10D3F or 0x10EC0<=c<=0x10EFF or 0x10F30<=c<=0x10F6F or 0x1EC70<=c<=0x1ECBF or 0x1ED00<=c<=0x1ED4F or 0x1EE00<=c<=0x1EEFF: return "AL"
    return "L"
runs=[];c=0
while c<0x110000:
    k=cls(c);d=c
    while d+1<0x110000 and cls(d+1)==k: d+=1
    if k!="L": runs.append((c,d,C.index(k)))
    c=d+1
out=[];prev=0
for a,b,k in runs:
    out.append(f"{a-prev:x},{b-a:x},{k:x}"); prev=b
s=";".join(out)
print(len(runs),len(s))
lines=[s[i:i+118] for i in range(0,len(s),118)]
print("\n".join('    + "'+l+'"' for l in lines))
