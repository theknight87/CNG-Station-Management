"""Phase 6i: owner "accept the proposals" (2026-09-24) for deliverables/unlinked-stations-review.xlsx.

Each accepted row becomes an owner_station_rulings row: the source name (read from the workbook, never retyped), the
suggested Station/Unit, and - when the Station lives in another Region - target_region_id. Rows with no suggestion
are not ruled. Rows HELD because the suggestion names a different place (reviewer check before applying) are listed.
Usage: python3 scripts/import/6i_rulings_sql.py review.xlsx stations.json > out.sql
"""
import hashlib, json, sys
import openpyxl

HELD = {13: 'السادات 2 suggested as السادات 3 (different number)',
        19: 'شبين الكوم has five Stations; the suggestion picks one',
        45: 'العبور: East also has العبور المنطقة الصناعية',
        65: 'موبيل العاشر suggested as موبيل المعادي (different place)',
        72: 'البراجيل القديمة suggested as البراجيل الجديدة (old vs new)',
        105: 'فويل أب: West has a separate Station فويل اب الدائرى',
        107: 'فويل أب: West has a separate Station فويل اب الدائرى',
        108: 'فويل أب: West has a separate Station فويل اب الدائرى'}
sha = hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest()
ws = openpyxl.load_workbook(sys.argv[1])['Names to review']
station_region = {}
for region, st, _units in json.load(open(sys.argv[2])):
    station_region.setdefault(st, set()).add(region)
q = lambda v: 'NULL' if v is None else "'" + str(v).replace("'", "''") + "'"
rows, held, none = [], [], 0
for i, r in enumerate(ws.iter_rows(min_row=2, values_only=True), start=2):
    region, src, st, un, why = r[0], r[1], r[8], r[9], r[10]
    if r[11] or r[12]:
        raise SystemExit(f'row {i}: owner columns filled; this generator is for "accept the proposals" only')
    if i in HELD:
        held.append(i); continue
    if not st:
        none += 1; continue
    regions = station_region.get(st, set())
    target = region if region in regions else (next(iter(regions)) if len(regions) == 1 else None)
    assert target, (i, st, regions)
    rows.append((region, src, st, un, None if target == region else target, f'unlinked review workbook row {i}; {why}'))
print(f'-- source workbook sha256 {sha}')
print("INSERT INTO owner_station_rulings (ruling_set, region_id, target_region_id, source_name_raw, station_name, unit_name, proposal_reason, evidence)")
print("SELECT '6I-2026-09-24', g.id, t.id, v.src, v.st, v.un, 'owner accepted the suggestion', v.ev FROM (VALUES")
print(',\n'.join(f'  ({q(a)}, {q(b)}, {q(c)}, {q(d)}, {q(e)}, {q(f)})' for a, b, c, d, e, f in rows))
print(') v(region, src, st, un, target, ev) JOIN regions g ON g.name = v.region LEFT JOIN regions t ON t.name = v.target;')
digest = hashlib.md5('\n'.join('|'.join(x or '' for x in row[:5]) for row in sorted(rows, key=lambda x: (x[0], x[1]))).encode()).hexdigest()
print(f'-- rows {len(rows)} md5 {digest}; held rows {held}; no suggestion {none}')
