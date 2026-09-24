import json, re, unicodedata, hashlib
def n(s): return re.sub(r'\s+', ' ', unicodedata.normalize('NFKC', '' if s is None else str(s))).strip().lower()
FN = {r['row']: r for r in json.load(open('file_full_norm.json'))}
S = {l.split('\t')[0]: (l.split('\t') + [''] * 8)[:8] for l in open('system_srvs.tsv', encoding='utf-8').read().splitlines()}
L = json.load(open('6n_leftovers.json'))
add = sorted(L['file_only'] + L['amb_f']); arc = sorted(L['sys_only'] + L['amb_s'])
fser = {n(FN[r]['serial']['serialNumber']) for r in add if FN[r]['serial']['serialNumber']}
sser = {n(S[i][4]) for i in arc if S[i][4]}
moved = fser & sser
held_f = [r for r in add if FN[r]['serial']['serialNumber'] and n(FN[r]['serial']['serialNumber']) in moved]
held_s = [i for i in arc if S[i][4] and n(S[i][4]) in moved]
add = [r for r in add if r not in held_f]; arc = [i for i in arc if i not in held_s]
def row(r):
    f = FN[r]; s = f['serial']; p = f['pressure']; a = f['last']; b = f['next']
    return [r, f['region'], f['station'], f['location'], s['serialNumber'], s['raw'], s['partNumber'], s['serialStatus'],
            f['manufacturer'], f['size_type'], f['inlet'], f['outlet'], p['raw'], p['min'], p['max'], p['unit'],
            a['value'], a['precision'], a['raw'], b['value'], b['precision'], b['raw'], f['notes']]
rows = [row(r) for r in add]
chunks = [rows[i:i + 82] for i in range(0, len(rows), 82)]
for k, c in enumerate(chunks):
    s = json.dumps(c, ensure_ascii=False, separators=(',', ':')); open(f'6o_add_{k}.json', 'w').write(s)
    print('add chunk', k, len(c), len(s), hashlib.md5(s.encode()).hexdigest(), "'" in s)
s = json.dumps(arc, separators=(',', ':')); open('6o_arc.json', 'w').write(s)
print('archive', len(arc), len(s), hashlib.md5(s.encode()).hexdigest())
print('held moved', len(held_f), len(held_s))
json.dump({'held_f': held_f, 'held_s': held_s}, open('6o_held.json', 'w'))
