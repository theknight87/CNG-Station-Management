"""Phase 6x (second batch): turn the owner's answers in srv-placeholder-vessels-unmatched.csv into 6x input.

Usage: python3 6x2_owner_names.py <workbook.xlsx> <owner csv (cp1256, tab)> <ph_match2.json> <out ph-format json>
Owner column filled -> that workbook Station; empty -> the single hint (owner: "empty = I agree with your suggestion";
with several hints, the first). The target must exist in the workbook's Storage rows in the SAME Region. A workbook
Station claimed by several placeholders whose Units would split several vessels (سيدي بشر 1/2) is held; a single
shared vessel is stored on each Unit, as in 6x. Only vessel data is taken; no Station is renamed.
"""
import collections, csv, json, re, sys, unicodedata, openpyxl
def fold(s):
    s = unicodedata.normalize('NFKC', str(s or '')).replace('ـ', '')
    for a, b in (('أ', 'ا'), ('إ', 'ا'), ('آ', 'ا'), ('ى', 'ي'), ('ة', 'ه')): s = s.replace(a, b)
    return re.sub(r'\s+', '', s).lower()
wb = openpyxl.load_workbook(sys.argv[1], data_only=True); ws = wb['رصيد المحطات']
st = collections.defaultdict(list)
for i, r in enumerate(ws.iter_rows(min_row=6, values_only=True), start=6):
    if r[1] and str(r[3]).strip() == 'Storage': st[(r[0], fold(r[1]))].append({'row': i, 'station': r[1]})
ph = {p['id']: p for p, raw, m in json.load(open(sys.argv[3]))}
plan = []
for r in list(csv.reader(open(sys.argv[2], encoding='cp1256'), delimiter='\t'))[1:]:
    if len(r) < 9 or not r[8].strip(): continue
    own, hint = r[7].strip(), [h.strip() for h in r[6].split('|') if h.strip()]
    tgt = own or (hint[0] if hint else None)
    m = st.get((r[0], fold(tgt))) if tgt else None
    if m: plan.append((ph[r[8].strip()], m))
use = collections.Counter(id(m) for p, m in plan)
out = [[p, None, m] for p, m in plan if not (use[id(m)] > 1 and len(m) > 1)]
json.dump(out, open(sys.argv[4], 'w'), ensure_ascii=False)
print(len(plan), 'matched;', len(plan) - len(out), 'held (shared, several vessels);', len(out), 'to apply')
