import sys, numpy as np, wave, struct
def rd(p):
    import soundfile
def read_wav(p):
    w = wave.open(p,'rb'); n=w.getnchannels(); sw=w.getsampwidth(); fr=w.getframerate()
    raw=w.readframes(w.getnframes()); w.close()
    if sw==4: a=np.frombuffer(raw,dtype="<i4").astype(np.float32)/2147483648
    elif sw==2: a=np.frombuffer(raw,dtype='<i2').astype(np.float32)/32768
    else: raise Exception('sw '+str(sw))
    return a.reshape(-1,n).mean(axis=1), fr
a,fa=read_wav(sys.argv[1]); b,fb=read_wav(sys.argv[2])
print(f"ours: {len(a)} samples @{fa}  ref: {len(b)} samples @{fb}")
if fa!=fb: print("RATE MISMATCH"); sys.exit(0)
n=min(len(a),len(b),fa*4)
# find lag via cross-correlation on first n samples
x=a[:n]-a[:n].mean(); y=b[:n]-b[:n].mean()
c=np.correlate(x, y[:n//2], mode='valid') if n>0 else np.array([0])
# Try both directions
best=None
for lag in range(-4000,4001):
    if lag>=0: xa=a[lag:lag+n-4000]; yb=b[:len(xa)]
    else: yb=b[-lag:-lag+n-4000]; xa=a[:len(yb)]
    m=min(len(xa),len(yb)); xa=xa[:m]; yb=yb[:m]
    if m<1000: continue
    den=np.sqrt((xa**2).sum()*(yb**2).sum())
    r=(xa*yb).sum()/den if den>0 else 0
    if best is None or r>best[0]: best=(r,lag,xa,yb)
r,lag,xa,yb=best
g=(xa*yb).sum()/((yb**2).sum()+1e-12)
err=xa-g*yb
snr=10*np.log10((yb**2).sum()/((err**2).sum()+1e-12))
print(f"lag={lag} corr={r:.4f} gain={g:.3f} SNR={snr:.1f} dB  rms_ours={np.sqrt((a**2).mean()):.4f} rms_ref={np.sqrt((b**2).mean()):.4f}")
