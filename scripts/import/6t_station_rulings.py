import json, re, unicodedata
o = json.load(open('/root/.claude/projects/-home-user-CNG-Station-Management/d53b468b-4afe-563b-ab9d-c38db1a55206/tool-results/mcp-Supabase-execute_sql-1790507703518.txt'))['result']
j = json.loads(o[o.index('[{'):o.rindex('}]') + 2])[0]['j']
def fold(s):
    s = unicodedata.normalize('NFKC', s or '').replace('ـ', '')
    for a, b in (('أ','ا'),('إ','ا'),('آ','ا'),('ى','ي'),('ة','ه')): s = s.replace(a, b)
    return re.sub(r'\s+', ' ', s).strip()
raws = sorted({(r['region'], r['raw']) for r in j['station']})
def raw(region, key):             # the file's exact spelling, found by a folded key
    c = [x for (g, x) in raws if g == region and fold(x) == fold(key)]; assert len(c) == 1, (region, key, c); return c[0]
def st(region, key):              # an existing Station's exact name
    c = [x for x in j['stations'][region] if fold(x) == fold(key)]; assert len(c) == 1, (region, key, c); return c[0]
rows = []
def m(region, rkey, target, units=None, rename=None): rows.append([region, raw(region, rkey), target, units, rename])
def new(region, rkey, units=None):
    r = raw(region, rkey); rows.append([region, r, r, units, None])
# Delta
m('Delta', 'الشهداء 2', st('Delta', 'الشهداء الجديدة 2'))
new('Delta', 'العيادية / شربين'); new('Delta', 'بلبيس الحصان'); new('Delta', 'حي الورش/ السادات 4')
m('Delta', 'شربين القديمة', st('Delta', 'شربين'))
m('Delta', 'قطور / امال', st('Delta', 'امل / قطور'), rename=raw('Delta', 'قطور / امال'))
# East
m('East', 'العاشر آل حكيم', st('East', 'آل حكيم العاشر'))
m('East', 'العبور', st('East', 'العبور المنطقة الصناعية'))
m('East', 'موبيل العاشر', st('East', 'موبيل-العاشر الجديدة'))
# Upper
m('Upper', 'سوهاج الروافع 1&2', st('Upper', 'سوهاج الروافع'))
# West
new('West', 'البراجيل القديمة'); new('West', 'الودي الصف'); new('West', 'عزبة السلام'); new('West', 'مساكن أبو بكر')
for k in ('الشيخ زايد', 'الشيخ زايد 1', 'الشيخ زايد 2'): m('West', k, st('West', 'زايد'))
for k in ('الصفوه أكتوبر', 'الصفوه أكتوبر 1', 'الصفوه أكتوبر 2'): m('West', k, st('West', 'الصفوة'))
h = raw('West', 'حدائق اكتوبر')
for k in ('حدائق اكتوبر', 'حدائق اكتوبر 1', 'حدائق اكتوبر 2'): m('West', k, h, [h + ' 1', h + ' 2'])
for k in ('دائري الهرم فويل أب', 'دائري الهرم 1 فويل أب', 'دائري الهرم 2 فويل أب'): m('West', k, st('West', 'فويل اب الدائرى'))
held = [x for x in raws if x[1] not in {r[1] for r in rows}]
print(len(rows), 'rows; held:', held)
s = json.dumps(rows, ensure_ascii=False, separators=(',', ':')); open('6t_payload.json', 'w').write(s)
import hashlib; print(len(s), hashlib.md5(s.encode()).hexdigest()); print(s)
