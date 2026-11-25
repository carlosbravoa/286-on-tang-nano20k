#!/usr/bin/env python3
"""Run the simulator tests and say which pass.

  tests/run.py [--jobs N] [--accept] [--dos CARD.img] [NAME ...]

Each test is a boot sector (tests/*.asm) on a floppy image, run in the simulator; its text
must contain what is expected, or its picture must be the one in tests/pictures.sha.
  --accept        take the pictures made now as the right ones (after looking at them:
                  they are left in build/t/NAME.ppm)
  --dos CARD.img  also boot DOS from a card image (make card) and run VER: 5 minutes more
  NAME ...        only the tests whose names start so
'monitor' drives the machine through tools/pc286ctl.py, as on the board. 'bench' also says
how many clock cycles its work took (fewer is a faster machine).
Needs: make sim build/simsys, nasm, mkfs.fat. About 10 minutes with 8 jobs.
"""
import concurrent.futures, hashlib, os, re, subprocess, sys, time
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)                                    # the simulators read build/*.hex from here
T = 'build/t'
BOOT = ['--expect', 'Booting from A:']
EGA = {'0D': (40, 200), '0E': (80, 200), '10': (80, 350), '12': (80, 480)}

# name: (source, nasm options, simulator, its options, what the text must have or None for a picture)
TESTS = {
    'adlib':    ('adlibtest', [], 'sim', ['--cycles', '12000000'], r'00 C0'),
    'kbd':      ('kbdtest', [], 'sim', BOOT + ['--type', r'\U'], r'E0 48 E0 C8'),
    'kbdpoll':  ('kbdpoll', [], 'sim', BOOT + ['--type', 'ab'], r'1E 9E 30 B0'),
    'move':     ('movetest', [], 'sim', ['--cycles', '12000000'], r'back from above 1 MB'),
    'pm':       ('pmtest', [], 'sim', ['--cycles', '12000000'], r'PRBEEF55'),
    'pmfault':  ('pmtest', ['-DFAULT'], 'sim', ['--cycles', '12000000'], r'PRBEEF55'),
    'ps2':      ('ps2test', [], 'sim', BOOT + ['--type', r'\m\l\u'], r'GO2814F8 090000 080000'),
    'mouse':    ('mousetest', [], 'sim', BOOT + ['--type', r'\ma\la\ua'],
                 r'FFFF 0003 ready 0000 0154 0068 0000 0001 0154 0068 0001 0000 0154 0068 0000'),
    'sb':       ('sbtest', [], 'simsys', ['--cycles', '20000000'], r'AA 02 01 I FF FF'),
    'sb2':      ('sbtest2', [], 'simsys', ['--cycles', '40000000'], r'AA00CF 0068 00CE'),
    'bench':    ('bench', [], 'simsys', ['--expect', 'DONE', '--type', ' ', '--after', '1', '--cycles', '200000000'], r'DONE'),
    'monitor':  ('kbdtest', [], 'simsys', ['--cycles', '400000000'], None),
    'remote':   ('remotetest', [], 'simsys', ['--cycles', '400000000'], None),
}
for m in ('01', '04', '06', '13'):
    TESTS['gfx' + m] = ('gfxtest', ['-DMODE=0x' + m], 'simsys', ['--cycles', '16000000'], None)
for m, (c, l) in EGA.items():
    TESTS['ega' + m] = ('egatest', ['-DMODE=0x' + m, '-DCOLS=%d' % c, '-DLINES=%d' % l], 'simsys', ['--cycles', '16000000'], None)
TESTS['egasplit'] = ('egatest', ['-DMODE=0x12', '-DCOLS=80', '-DLINES=480', '-DSPLIT=300'], 'simsys', ['--cycles', '16000000'], None)
TESTS['egawide'] = ('egatest', ['-DMODE=0x0D', '-DCOLS=40', '-DLINES=200', '-DWIDE=21'], 'simsys', ['--cycles', '16000000'], None)
PICTURES = [n for n in TESTS if n.startswith(('gfx', 'ega'))]

def sh(*a, **k): return subprocess.run(a, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace', **k).stdout

def image(name):
    src, opts = TESTS[name][:2]
    sh('nasm', *opts, '-f', 'bin', 'tests/%s.asm' % src, '-o', '%s/%s.bin' % (T, name))
    flp = '%s/%s.flp' % (T, name)
    with open(T + '/blank.flp', 'rb') as f: d = bytearray(f.read())
    code = open('%s/%s.bin' % (T, name), 'rb').read()
    d[62:62 + len(code)] = code
    open(flp, 'wb').write(d)
    sh('python3', 'tools/mkcard.py', '%s/%s.img' % (T, name), '--floppy', flp)
    os.remove(flp)
    return '%s/%s.img' % (T, name)

def monitor(name, img):
    """the machine driven from outside, as on the board"""
    pty = '%s/%s.pty' % (T, name)
    sim = subprocess.Popen(['build/simsys', '--sd', img, '--waits', '4', '--cycles', '400000000', '--pty', pty],
                           stdout=open('%s/%s.out' % (T, name), 'w'), stderr=subprocess.STDOUT)
    ctl = lambda *a: sh('python3', 'tools/pc286ctl.py', '--port', pty, '--timeout', '300', *a)
    try:
        while not os.path.exists(pty): time.sleep(0.2)
        ctl('wait', 'Booting from A:', '900', '4', '4')
        ctl('key', 'up'); ctl('type', 'a')
        ctl('poke', '7CAD', '5F')                       # the program itself: it now prints _ for a space
        ctl('key', 'f1')
        got = ctl('screen', '5', '5').strip()
        ctl('poke', 'B8000', '48', '1F'); got += ' ' + ctl('peek', 'B8000', '2').split(':')[1].split('  ')[0].strip()
        ctl('poke', 'B8280', '58')                      # row 4 no longer says Booting: the reset must bring it back
        ctl('reset'); ctl('wait', 'Booting from A:', '900', '4', '4'); ctl('key', 'f2')
        got += ' / ' + ctl('screen', '5', '5').strip()
    finally:
        sim.kill(); sim.wait()
        if os.path.islink(pty): os.remove(pty)
    want = 'E0 48 E0 C8 1E 9E 3B_BB_ 48 1f / 3C BC'
    return got == want, got

def remote(name, img):
    """drive B: served by tools/pc286ctl.py"""
    pty = '%s/%s.pty' % (T, name); disk = '%s/%s.b' % (T, name)
    if os.path.exists(disk): os.remove(disk)
    sh(mkfs, '--invariant', '-C', disk, '1440')
    sim = subprocess.Popen(['build/simsys', '--sd', img, '--waits', '4', '--cycles', '400000000', '--pty', pty],
                           stdout=open('%s/%s.out' % (T, name), 'w'), stderr=subprocess.STDOUT)
    ctl = ['python3', 'tools/pc286ctl.py', '--port', pty, '--timeout', '300']
    serve = None
    try:
        while not os.path.exists(pty): time.sleep(0.2)
        serve = subprocess.Popen(ctl + ['serve', disk], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        end = time.time() + 900
        while b'286' != open(disk, 'rb').read()[6 * 512:6 * 512 + 3] and time.time() < end: time.sleep(1)
        time.sleep(20)
        serve.terminate(); serve.wait(); serve = None
        got = sh(*ctl, 'screen', '5', '5').strip()
    finally:
        if serve: serve.kill()
        sim.kill(); sim.wait()
        if os.path.islink(pty): os.remove(pty)
    d = open(disk, 'rb').read()
    return got == 'mkfs.fatWB2' and d[6 * 512:7 * 512] == b'286' + d[3:512], got

def run(name):
    t0 = time.time()
    try:
        img = image(name)
        src, opts, sim, args, want = TESTS[name]
        if name == 'monitor': ok, note = monitor(name, img)
        elif name == 'remote': ok, note = remote(name, img)
        else:
            cmd = ['build/' + sim, '--sd', img] + args
            if sim == 'simsys': cmd += ['--waits', '4', '--ppm', '%s/%s.ppm' % (T, name)]
            out = sh(*cmd); open('%s/%s.out' % (T, name), 'w').write(out)
            text = ' '.join(out.split('Booting from A:')[-1].split('[')[0].split())
            if name in PICTURES:
                note = hashlib.sha256(open('%s/%s.ppm' % (T, name), 'rb').read()).hexdigest()[:16]
                ok = SHA.get(name) == note
                if ACCEPT: SHA[name] = note; ok = True
                elif not ok: note = 'picture changed: look at %s/%s.ppm' % (T, name) if name in SHA else 'no picture to compare with (--accept)'
            else:
                ok = re.search(want, text) is not None; note = text[:70]
                if name == 'bench': note = re.search(r'\[(\d+) cycles', out).group(1) + ' cycles'
    except subprocess.CalledProcessError as e: ok, note = False, (e.stdout or str(e)).strip()[-200:]
    except Exception as e: ok, note = False, repr(e)
    return name, ok, note, time.time() - t0

def dos(card):
    out = sh('build/sim', '--sd', card, '--cycles', '400000000', '--expect', 'C:\\>', '--type', 'ver\\r', '--after', '12000000', '--quiet', '--screen')
    open(T + '/dos.out', 'w').write(out)
    return 'dos', 'FreeDOS' in out.split('ver')[-1], 'boots, VER answers' if 'FreeDOS' in out else 'see %s/dos.out' % T, 0

a = sys.argv[1:]; jobs = 8; ACCEPT = False; card = None; only = []
while a:
    k = a.pop(0)
    if k == '--jobs': jobs = int(a.pop(0))
    elif k == '--accept': ACCEPT = True
    elif k == '--dos': card = a.pop(0)
    elif k.startswith('-'): raise SystemExit(__doc__)
    else: only.append(k)
os.makedirs(T, exist_ok=True)
SHAFILE = 'tests/pictures.sha'
SHA = dict(l.split() for l in open(SHAFILE)) if os.path.exists(SHAFILE) else {}
mkfs = '/usr/sbin/mkfs.fat' if os.path.exists('/usr/sbin/mkfs.fat') else 'mkfs.fat'
if os.path.exists(T + '/blank.flp'): os.remove(T + '/blank.flp')
sh(mkfs, '--invariant', '-C', T + '/blank.flp', '1440')
names = [n for n in TESTS if not only or any(n.startswith(o) for o in only)]
bad = 0
with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
    work = [ex.submit(run, n) for n in names] + ([ex.submit(dos, card)] if card else [])
    for f in concurrent.futures.as_completed(work):
        name, ok, note, secs = f.result(); bad += not ok
        print('%-4s %-9s %4d s  %s' % ('ok' if ok else 'FAIL', name, secs, note), flush=True)
if ACCEPT: open(SHAFILE, 'w').write(''.join('%s %s\n' % kv for kv in sorted(SHA.items())))
print('%d of %d passed' % (len(work) - bad, len(work)))
sys.exit(1 if bad else 0)
