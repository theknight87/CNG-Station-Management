"""Phase 6n pairing: station snapshot vs installed SRVs (see migration 20260925000000_srv_snapshot_update_6n.sql).

Run in a work dir holding file_norm.json (from 6n_normalize.ts) and system_srvs.tsv
(id, region, station, location, serial, set_pressure, mapping_status, unit). Writes 6n_payload.json.
Only unambiguous pairs are proposed; everything else is counted and left for the owner.
"""
import json, re, unicodedata, collections
def n(s): return re.sub(r'\s+', ' ', unicodedata.normalize('NFKC', '' if s is None else str(s))).strip().lower()
F = json.load(open('file_norm.json'))
S = [dict(zip(['id','region','station','location','serial','pressure','status','unit'], (l.split('\t')+['']*8)[:8]))
     for l in open('system_srvs.tsv', encoding='utf-8').read().splitlines()]
fk = lambda r: (n(r['area']), n(r['station_txt']), n(r['location_txt']))
sk = lambda d: (n(d['region']), n(d['station']), n(d['location']))
fs = lambda r: r['serial_norm']['serialNumber'] or ''
fp = lambda r: r['pressure_norm']['raw'] or ''
# 1 exact
Fleft = collections.defaultdict(list); Sleft = collections.defaultdict(list)
for r in F: Fleft[fk(r) + (fs(r), n(fp(r)))].append(r)
for d in S: Sleft[sk(d) + (d['serial'], n(d['pressure']))].append(d)
same = 0
for k in list(Fleft):
    m = min(len(Fleft[k]), len(Sleft.get(k, [])))
    same += m; Fleft[k] = Fleft[k][m:]
    if k in Sleft: Sleft[k] = Sleft[k][m:]
fl = [r for v in Fleft.values() for r in v]; sl = [d for v in Sleft.values() for d in v]
# 2 pressure change: same place + same non-empty serial, only when leftover counts are equal in the group
G1f = collections.defaultdict(list); G1s = collections.defaultdict(list)
for r in fl:
    if fs(r): G1f[fk(r) + (fs(r),)].append(r)
for d in sl:
    if d['serial']: G1s[sk(d) + (d['serial'],)].append(d)
upd = []; used_f = set(); used_s = set(); held_p = 0
for k in G1f:
    a, b = G1f[k], G1s.get(k, [])
    if not b: continue
    if len(a) == len(b):
        pa = sorted(a, key=lambda r: n(fp(r))); pb = sorted(b, key=lambda d: n(d['pressure']))
        # all system rows share the serial; pairing among identical-serial rows only matters if their pressures differ
        for r, d in zip(pa, pb):
            upd.append(('pressure', d, r)); used_f.add(r['row']); used_s.add(d['id'])
    else: held_p += min(len(a), len(b))
fl = [r for r in fl if r['row'] not in used_f]; sl = [d for d in sl if d['id'] not in used_s]
# 3 serial change: same place + same pressure, exactly one leftover on each side
G2f = collections.defaultdict(list); G2s = collections.defaultdict(list)
for r in fl: G2f[fk(r) + (n(fp(r)),)].append(r)
for d in sl: G2s[sk(d) + (n(d['pressure']),)].append(d)
blank = ambiguous = 0
for k in G2f:
    a, b = G2f[k], G2s.get(k, [])
    if not b: continue
    if len(a) == 1 and len(b) == 1:
        if fs(a[0]) or a[0]['serial_norm']['partNumber']: upd.append(('serial', b[0], a[0])); used_f.add(a[0]['row']); used_s.add(b[0]['id'])
        else: blank += 1
    else: ambiguous += min(len(a), len(b))
fl = [r for r in fl if r['row'] not in used_f]; sl = [d for d in sl if d['id'] not in used_s]
c = collections.Counter(u[0] for u in upd)
print('same', same, dict(c), 'held: pressure groups uneven', held_p, 'serial-blank-in-file', blank, 'ambiguous', ambiguous,
      'left file-only', len(fl), 'left system-only', len(sl))
json.dump([{'id': d['id'], 'kind': k, 'file_row': r['row'],
            'serial_number': r['serial_norm']['serialNumber'], 'serial_number_raw': r['serial_norm']['raw'],
            'part_number': r['serial_norm']['partNumber'], 'serial_status': r['serial_norm']['serialStatus'],
            'set_pressure_raw': r['pressure_norm']['raw'], 'pressure_min': r['pressure_norm']['min'],
            'pressure_max': r['pressure_norm']['max'], 'pressure_unit': r['pressure_norm']['unit'],
            **({'last_calibration_date': r['last_norm']['value'], 'last_calibration_precision': r['last_norm']['precision'], 'last_calibration_raw': r['last_norm']['raw'],
                'next_calibration_date': r['next_norm']['value'], 'next_calibration_precision': r['next_norm']['precision'], 'next_calibration_raw': r['next_norm']['raw']} if k == 'serial' else {})}
           for k, d, r in sorted(upd, key=lambda u: u[1]['id'])], open('6n_payload.json', 'w'), ensure_ascii=False, sort_keys=True)
