"""Phase 6x: extract the Storage rows of the owner's storage/recovery workbook that match a 6r placeholder vessel.

Usage: python3 6x_vessels_extract.py <workbook.xlsx> <ph_match2.json> <out.json>
Match = the placeholder's SRV raw Station name (or Unit name) equals the workbook's Station cell after whitespace/Arabic
letter folding, in the same Region. Placeholders whose workbook serial already exists on a vessel of another Station
are excluded (held for the owner). Cells are passed on raw; normalization is done by 6x_vessels_normalize.ts.
"""
import json, sys, openpyxl
wb = openpyxl.load_workbook(sys.argv[1], data_only=True); ws = wb['رصيد المحطات']
cells = {i: list(r[:10]) for i, r in enumerate(ws.iter_rows(min_row=6, values_only=True), start=6)}
HOLD = set(json.loads(sys.argv[4])) if len(sys.argv) > 4 else set()
out = []
for p, raw, m in json.load(open(sys.argv[2])):
    if not m or p['id'] in HOLD: continue
    for k, f in enumerate(m):
        c = cells[int(f['row'])]
        out.append({'vessel_id': p['id'], 'unit_id': p['unit_id'], 'k': k, 'row': int(f['row']),
                    'cells': {'Area': c[0], 'Station': c[1], 'Type OF Compressor': c[2], 'Location': c[3], 'Manufacturer': c[4],
                              'Serial Number': c[5], 'Last Calibration Date': {'__date': c[6].isoformat()} if hasattr(c[6], 'isoformat') else c[6],
                              'Next Calibration Date': {'__date': c[7].isoformat()} if hasattr(c[7], 'isoformat') else c[7], 'Notes': c[9]}})
json.dump(out, open(sys.argv[3], 'w'), ensure_ascii=False); print(len(out), len({o['vessel_id'] for o in out}))
