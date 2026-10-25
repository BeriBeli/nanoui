#!/usr/bin/env python3
"""Fail closed on every shipped ELF's architecture, interpreter and ABI."""
import argparse,hashlib,json,re,shutil,subprocess
from pathlib import Path
ALLOWED={'libc.so.6','ld-linux-x86-64.so.2','libpthread.so.0','libdl.so.2','libutil.so.1','libm.so.6','librt.so.1'}
def version(s):return tuple(map(int,s.split('.')))
def audit(path,readelf):
    text=subprocess.check_output([readelf,'-W','-h','-l','-d','--version-info',str(path)],text=True)
    if not re.search(r'Machine:.*(Advanced Micro Devices X86-64|AMD x86-64)',text):raise ValueError('Wrong architecture: '+str(path))
    if not re.search(r'Class:\s+ELF64',text) or 'little endian' not in text:raise ValueError('Wrong ELF encoding')
    interp=re.findall(r'Requesting program interpreter:\s*([^\]]+)',text)
    if interp and interp!=['/lib64/ld-linux-x86-64.so.2']:raise ValueError('Wrong interpreter: '+repr(interp))
    if '(RPATH)' in text or '(RUNPATH)' in text:raise ValueError('Unexpected RPATH/RUNPATH: '+str(path))
    needed=re.findall(r'\(NEEDED\).*\[([^\]]+)\]',text)
    if set(needed)-ALLOWED:raise ValueError('Unexpected dependency: '+repr(set(needed)-ALLOWED))
    # Names in version-need records; no accidental definition-table matches.
    symbols=re.findall(r'Name:\s+(\S+)',text.split('Version needs section',1)[-1]) if 'Version needs section' in text else []
    versions=[]
    for name in symbols:
        if not re.fullmatch(r'GLIBC_[0-9.]+',name):raise ValueError('Unexpected required ABI: '+name)
        v=name.removeprefix('GLIBC_');versions.append(v)
        if version(v)>version('2.17'):raise ValueError('Requires '+name+': '+str(path))
    return {'file':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'interpreter':interp[0] if interp else None,'needed':needed,'max_glibc':max(versions,key=version) if versions else None,'status':'pass'}
def main():
    ap=argparse.ArgumentParser();ap.add_argument('directory',type=Path);ap.add_argument('--output',type=Path);args=ap.parse_args()
    readelf=shutil.which('readelf') or shutil.which('llvm-readelf')
    if not readelf:raise SystemExit('readelf or llvm-readelf required')
    results=[]
    for p in sorted(args.directory.rglob('*')):
        if not p.is_file() or p.is_symlink():continue
        with p.open('rb') as f:magic=f.read(4)
        if magic==b'\x7fELF':results.append(audit(p,readelf))
    if not results:raise SystemExit('No ELF files found; refusing empty audit')
    out=json.dumps({'target':'x86_64-linux.3.10-gnu.2.17','files':results,'scope':'Static ABI only; dlopen and kernel paths require target acceptance'},indent=2)+'\n'
    if args.output:args.output.write_text(out)
    print(out)
if __name__=='__main__':main()
