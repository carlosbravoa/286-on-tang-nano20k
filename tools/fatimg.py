#!/usr/bin/env python3
"""Small FAT12/FAT16 image tool for floppy images and hard disk partitions.
  fatimg.py IMAGE ls [DIR]
  fatimg.py IMAGE get NAME [OUTFILE]
  fatimg.py IMAGE put FILE [NAME]        (replaces an existing file; NAME may be DIR/NAME)
  fatimg.py IMAGE rm NAME
  fatimg.py IMAGE mkdir NAME
  fatimg.py IMAGE putdir HOSTDIR [DIR]   (a whole directory of this computer, with what is in it)
An image may be a partition inside a disk image: IMAGE@SECTOR."""
import mmap, struct, sys, os

class Fat:
    def __init__(self, path):
        self.off = 0
        if '@' in path:
            path, s = path.rsplit('@', 1); self.off = int(s) * 512
        self.path = path
        self.f = open(path, 'r+b')                      # the image stays on disk: it may be gigabytes
        self.d = mmap.mmap(self.f.fileno(), 0)
        b = self.d[self.off:self.off + 512]
        (self.bps, self.spc, self.rsvd, self.nfat, self.nroot, tot16, _, self.spf) = struct.unpack_from('<HBHBHHBH', b, 11)
        tot = tot16 or struct.unpack_from('<I', b, 32)[0]
        self.fat0 = self.off + self.rsvd * self.bps
        self.root = self.fat0 + self.nfat * self.spf * self.bps
        self.data = self.root + self.nroot * 32
        self.nclus = (tot * self.bps - (self.data - self.off)) // (self.spc * self.bps)
        self.f16 = self.nclus >= 4085
        self.csize = self.spc * self.bps
    def save(self): self.d.flush()
    def fat(self, n):
        if self.f16: return struct.unpack_from('<H', self.d, self.fat0 + n * 2)[0]
        v = struct.unpack_from('<H', self.d, self.fat0 + n * 3 // 2)[0]
        return v >> 4 if n & 1 else v & 0xFFF
    def setfat(self, n, v):
        for k in range(self.nfat):
            base = self.fat0 + k * self.spf * self.bps
            if self.f16: struct.pack_into('<H', self.d, base + n * 2, v)
            else:
                o = base + n * 3 // 2
                w = struct.unpack_from('<H', self.d, o)[0]
                w = (w & 0x000F) | (v << 4) if n & 1 else (w & 0xF000) | (v & 0xFFF)
                struct.pack_into('<H', self.d, o, w)
    def eoc(self, v): return v >= (0xFFF8 if self.f16 else 0xFF8)
    def chain(self, c):
        r = []
        while 2 <= c and not self.eoc(c): r.append(c); c = self.fat(c)
        return r
    def coff(self, c): return self.data + (c - 2) * self.csize
    def dir_slots(self, clus=None):
        """offsets of the 32-byte entries of a directory (root if clus is None)"""
        if clus is None: return [self.root + i * 32 for i in range(self.nroot)]
        return [self.coff(c) + i for c in self.chain(clus) for i in range(0, self.csize, 32)]
    @staticmethod
    def name83(n):
        n = n.upper(); base, _, ext = n.partition('.')
        return (base.ljust(8)[:8] + ext.ljust(3)[:3]).encode('ascii')
    def entries(self, clus=None):
        for o in self.dir_slots(clus):
            e = self.d[o:o + 32]
            if e[0] == 0: break
            if e[0] == 0xE5 or e[11] == 0x0F or e[11] & 8: continue
            name = e[0:8].decode('cp437').rstrip(); ext = e[8:11].decode('cp437').rstrip()
            yield o, (name + '.' + ext if ext else name), e[11], struct.unpack_from('<H', e, 26)[0], struct.unpack_from('<I', e, 28)[0]
    def find(self, path):
        """-> (directory cluster or None, entry offset or None, short name)"""
        parts = [p for p in path.replace('\\', '/').split('/') if p]
        clus = None
        for p in parts[:-1]:
            for o, n, attr, c, size in self.entries(clus):
                if n == p.upper() and attr & 0x10: clus = c; break
            else: raise SystemExit('no directory ' + p)
        for o, n, attr, c, size in self.entries(clus):
            if n == parts[-1].upper(): return clus, o, parts[-1]
        return clus, None, parts[-1]
    def read(self, path):
        clus, o, _ = self.find(path)
        if o is None: raise SystemExit('no file ' + path)
        c, size = struct.unpack_from('<H', self.d, o + 26)[0], struct.unpack_from('<I', self.d, o + 28)[0]
        return b''.join(bytes(self.d[self.coff(k):self.coff(k) + self.csize]) for k in self.chain(c))[:size]
    def remove(self, path):
        clus, o, _ = self.find(path)
        if o is None: return
        for c in self.chain(struct.unpack_from('<H', self.d, o + 26)[0]): self.setfat(c, 0)
        self.d[o] = 0xE5
    def alloc(self, need):
        free = []; c = getattr(self, 'next_free', 2)
        while len(free) < need and c < self.nclus + 2:
            if self.fat(c) == 0: free.append(c)
            c += 1
        if len(free) < need:
            if c > 2 and getattr(self, 'next_free', 2) > 2: self.next_free = 2; return self.alloc(need)
            raise SystemExit('image full')
        self.next_free = free[-1] + 1 if free else c
        for i, c in enumerate(free): self.setfat(c, free[i + 1] if i + 1 < need else (0xFFFF if self.f16 else 0xFFF))
        return free
    def add_entry(self, clus, name, attr, first, size):
        """a new entry in the directory at cluster clus (None: the root); a subdirectory grows if full"""
        e = bytearray(32); e[0:11] = self.name83(name); e[11] = attr
        struct.pack_into('<HH', e, 22, 0, 0x5B77)                     # a fixed date
        struct.pack_into('<HI', e, 26, first, size)
        for o in self.dir_slots(clus):
            if self.d[o] in (0, 0xE5): self.d[o:o + 32] = e; return
        if clus is None: raise SystemExit('root directory full')
        c = self.alloc(1)[0]
        self.setfat(self.chain(clus)[-1], c)
        self.d[self.coff(c):self.coff(c) + self.csize] = bytes(self.csize)
        self.d[self.coff(c):self.coff(c) + 32] = e
    def write(self, path, data, attr=0x20):
        self.remove(path)
        clus, _, name = self.find(path)
        free = self.alloc((len(data) + self.csize - 1) // self.csize)
        for i, c in enumerate(free):
            chunk = data[i * self.csize:(i + 1) * self.csize]
            self.d[self.coff(c):self.coff(c) + len(chunk)] = chunk
        self.add_entry(clus, name, attr, free[0] if free else 0, len(data))
    def mkdir(self, path):
        clus, o, name = self.find(path)
        if o is not None: return
        c = self.alloc(1)[0]
        self.d[self.coff(c):self.coff(c) + self.csize] = bytes(self.csize)
        for i, (n, k) in enumerate((('.', c), ('..', clus or 0))):
            e = bytearray(32); e[0:11] = n.ljust(11).encode(); e[11] = 0x10
            struct.pack_into('<HH', e, 22, 0, 0x5B77); struct.pack_into('<H', e, 26, k)
            self.d[self.coff(c) + i * 32:self.coff(c) + i * 32 + 32] = e
        self.add_entry(clus, name, 0x10, c, 0)
    def copy_from(self, src, sclus=None, prefix=''):
        """copy a whole directory tree of another image"""
        for o, n, attr, c, size in list(src.entries(sclus)):
            if n in ('.', '..'): continue
            if attr & 0x10: self.mkdir(prefix + n); self.copy_from(src, c, prefix + n + '/')
            else:
                data = b''.join(bytes(src.d[src.coff(k):src.coff(k) + src.csize]) for k in src.chain(c))[:size]
                self.write(prefix + n, data, attr)
    def copy_host(self, top, prefix=''):
        """copy a directory of this computer; names that are not 8.3 are left out"""
        import re
        for n in sorted(os.listdir(top)):
            p = os.path.join(top, n)
            if not re.fullmatch(r"[A-Za-z0-9_!#$%&'()@^`{}~-]{1,8}(\.[A-Za-z0-9_!#$%&'()@^`{}~-]{0,3})?", n):
                print('left out (not an 8.3 name): ' + p, file=sys.stderr); continue
            if os.path.isdir(p): self.mkdir(prefix + n); self.copy_host(p, prefix + n + '/')
            else: self.write(prefix + n, open(p, 'rb').read())

if __name__ == '__main__':
    if len(sys.argv) < 3: raise SystemExit(__doc__)
    f = Fat(sys.argv[1]); cmd = sys.argv[2]; a = sys.argv[3:]
    if cmd == 'ls':
        clus = None
        if a:
            _, o, _ = f.find(a[0]); clus = struct.unpack_from('<H', f.d, o + 26)[0]
        for o, n, attr, c, size in f.entries(clus): print('%-12s %s %8d' % (n, '<DIR>' if attr & 0x10 else '     ', size))
        print('FAT%d, %d bytes per cluster, %d clusters free' % (16 if f.f16 else 12, f.csize, sum(1 for c in range(2, f.nclus + 2) if f.fat(c) == 0)))
    elif cmd == 'get':
        data = f.read(a[0])
        if len(a) > 1: open(a[1], 'wb').write(data)
        else: sys.stdout.buffer.write(data)
    elif cmd == 'put':
        f.write(a[1] if len(a) > 1 else os.path.basename(a[0]), open(a[0], 'rb').read()); f.save()
    elif cmd == 'rm':
        f.remove(a[0]); f.save()
    elif cmd == 'mkdir':
        f.mkdir(a[0]); f.save()
    elif cmd == 'putdir':
        pre = ''
        if len(a) > 1:
            parts = [p for p in a[1].replace('\\', '/').split('/') if p]
            for i in range(len(parts)): f.mkdir('/'.join(parts[:i + 1]))
            pre = '/'.join(parts) + '/'
        f.copy_host(a[0], pre); f.save()
