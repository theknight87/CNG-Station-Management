"""Phase 6x leftovers: placeholder vessels the owner's workbook did not match exactly, with name hints only.

Usage: python3 6x_unmatched_csv.py <workbook.xlsx> <ph_match2.json> <out.csv>
Hints are the workbook Station names (same Region) that look alike; nothing is decided here. Pairs the owner has
rejected are never suggested.
"""
import collections, csv, difflib, json, re, sys, unicodedata, openpyxl
REJECTED = {('الودي الصف', 'الفهميين الصف'), ('البراجيل القديمة', 'البراجيل الجديدة')}
HELD = {'ابو المطامير كتكوت', 'محرم بك 1', 'العطف المحموديه', 'غيط العنب 1'}
def fold(s):
    s = unicodedata.normalize('NFKC', str(s or '')).replace('ـ', '')
    for a, b in (('أ', 'ا'), ('إ', 'ا'), ('آ', 'ا'), ('ى', 'ي'), ('ة', 'ه')): s = s.replace(a, b)
    return re.sub(r'\s+', '', s).lower()
wb = openpyxl.load_workbook(sys.argv[1], data_only=True); ws = wb['رصيد المحطات']
st = collections.defaultdict(collections.Counter)
for r in ws.iter_rows(min_row=6, values_only=True):
    if r[1] and str(r[3]).strip() == 'Storage': st[r[0]][r[1]] += 1
w = csv.writer(open(sys.argv[3], 'w', newline='', encoding='utf-8-sig'))
w.writerow(['المنطقة', 'المحطة', 'الـ Unit', 'اسم الريليفات في الملف', 'عدد الريليفات', 'السبب', 'أقرب أسماء في شيت الخزانات (اقتراح بس)', 'الاسم الصح في الشيت', 'vessel_id'])
n = 0
for p, raw, m in json.load(open(sys.argv[2])):
    if m and p['unit'] not in HELD: continue
    name = (raw or [None])[0] or p['unit']
    if p['unit'] in HELD:
        why = 'سيريال الخزان موجود في السيستم على محطة تانية: ' + ' | '.join(sorted({f['station'] for f in m}))
        hint = ' | '.join(sorted({f['station'] for f in m}))
    else:
        k = fold(name)
        c = [s for s in st[p['region']] if (difflib.SequenceMatcher(None, k, fold(s)).ratio() > 0.6 or k[:5] in fold(s))
             and (name, s) not in REJECTED and (p['station'], s) not in REJECTED]
        why = 'الاسم مش موجود في الشيت بنفس الكتابة'; hint = ' | '.join(c[:4])
    w.writerow([p['region'], p['station'], p['unit'], name, p['nsrv'], why, hint, '', p['id']]); n += 1
print(n)
