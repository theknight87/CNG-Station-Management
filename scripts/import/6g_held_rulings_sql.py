"""Phase 6g follow-up: owner rulings (2026-09-24) for the 7 held review-workbook rows.

Source spellings are read from the workbook (never retyped); Station and Unit names are the owner's own words:
  rows 23, 24   -> Station "الكيلو 21", Units "الكيلو 21 - 1" / "الكيلو 21 - 2"
  rows 61-64    -> Station "محور التعمير", Units "محور التعمير 1" / "محور التعمير 2" (the Unit number the name carries)
  row 201       -> Station "الروافع"; the name covers Units 1 and 2, so no single Unit is proven
"""
import hashlib, sys
import openpyxl

RULINGS = {
    23: ('الكيلو 21', 'الكيلو 21 - 1'),
    24: ('الكيلو 21', 'الكيلو 21 - 2'),
    61: ('محور التعمير', 'محور التعمير 1'),   # ك/1/21
    62: ('محور التعمير', 'محور التعمير 2'),   # ك/2/21
    63: ('محور التعمير', 'محور التعمير 1'),   # ك/21/1
    64: ('محور التعمير', 'محور التعمير 2'),   # ك/21/2
    201: ('الروافع', None),                   # 1&2
}
ws = openpyxl.load_workbook(sys.argv[1])['Names to review']
q = lambda v: 'NULL' if v is None else "'" + str(v).replace("'", "''") + "'"
out, digest_rows = [], []
for i, r in enumerate(ws.iter_rows(min_row=2, values_only=True), start=2):
    if i not in RULINGS:
        continue
    region, src, other, found = r[0], r[1], r[2], r[3]
    st, un = RULINGS[i]
    out.append(f"  ({q(region)}, {q(src)}, {q(other)}, {q(st)}, {q(un)}, 'owner ruling 2026-09-24 for a held proposal', "
               f"{q(f'review workbook row {i}; found in: {found}')})")
    digest_rows.append((region, src, other or '', st, un or ''))
assert len(out) == 7, len(out)
print("INSERT INTO owner_station_rulings (ruling_set, region_id, source_name_raw, other_spelling_raw, station_name, unit_name, proposal_reason, evidence)")
print("SELECT '6G-2026-09-24', g.id, v.src, v.oth, v.st, v.un, v.why, v.ev FROM (VALUES")
print(',\n'.join(out))
print(') v(region, src, oth, st, un, why, ev) JOIN regions g ON g.name = v.region;')
print('-- md5 ' + hashlib.md5('\n'.join('|'.join(x) for x in sorted(digest_rows, key=lambda x: (x[0], x[1]))).encode()).hexdigest())
