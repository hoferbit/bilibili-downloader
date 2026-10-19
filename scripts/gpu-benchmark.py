#!/usr/bin/env python3
"""Offline same-input benchmark. Prepare sample/motion.mp4 and matching ASS first.
No credentials or network are used. Run after the release bilibench build.
"""
import json, pathlib, re, subprocess, threading, time
root = pathlib.Path(__file__).resolve().parent.parent
work = root / 'build/gpu-benchmark'
results = []
for clip in ['sample', 'motion']:
    for renderer, codec, segments, rate in [('libass','x264',4,None),('metal','x264',4,None),('libass','h264',1,None),('metal','h264',1,None),('metal','h264',1,3000)]:
        name = f'final-{clip}-{renderer}-{codec}-{rate or 0}'
        print('START',name,flush=True)
        stop = threading.Event(); util = []
        def monitor():
            while not stop.is_set():
                p = subprocess.run(['ioreg','-r','-d','1','-c','AGXAccelerator'],capture_output=True,text=True)
                m = re.search(r'"Device Utilization %"=(\d+)',p.stdout)
                if m: util.append(int(m[1]))
                stop.wait(0.5)
        thread = threading.Thread(target=monitor); thread.start()
        cmd = ['/usr/bin/time','-p',str(root/'.build/release/bilibench'),str(work/(clip+'.mp4')),str(work/(clip+'.ass')),
               str(work/name),renderer,codec,str(segments),'30']
        if rate: cmd.append(str(rate))
        p = subprocess.run(cmd,capture_output=True,text=True)
        stop.set(); thread.join()
        print('EXIT',p.returncode,p.stdout,p.stderr[-500:],flush=True)
        result = dict(name=name, clip=clip, renderer=renderer, encoder=codec, segments=segments, kbps=rate, exit=p.returncode)
        m = re.search(r'wall=([\d.]+)s speed=([\d.]+)x',p.stdout)
        if m:
            result.update(seconds=float(m[1]), speed=float(m[2]))
        times = dict(re.findall(r'^(real|user|sys) ([\d.]+)$',p.stderr,re.M))
        if 'user' in times and 'seconds' in result:
            result['cpu_percent'] = round((float(times['user'])+float(times['sys'])) / result['seconds'] * 100,1)
        if util: result['system_gpu_percent'] = round(sum(util)/len(util),1)
        out = work/name/'output.mp4'
        if out.exists():
            result['bytes'] = out.stat().st_size
            subprocess.run(['ffmpeg','-v','error','-y','-ss','12','-i',str(out),'-frames:v','1','-vf','scale=960:-1',str(work/(name+'.jpg'))],capture_output=True)
        results.append(result)
        (work/'final-results.json').write_text(json.dumps(results,indent=2))
        print(json.dumps(result),flush=True)
