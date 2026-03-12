#!/usr/bin/env python3
"""
Generate materials.txt from Excel file for sbatch.sh
Run this on the server where openpyxl is available
"""
import sys
import os

try:
    import openpyxl
except ImportError:
    print("Error: openpyxl not installed")
    sys.exit(1)

xlsx_path = sys.argv[1] if len(sys.argv) > 1 else None
if not xlsx_path:
    print("Usage: python generate_materials_list.py <excel_file>")
    sys.exit(1)

if not os.path.exists(xlsx_path):
    print(f"Error: File not found: {xlsx_path}")
    sys.exit(1)

wb = openpyxl.load_workbook(xlsx_path)
ws = wb.active

materials = []
for row_idx, row in enumerate(ws.iter_rows(values_only=True), start=1):
    if row_idx == 1:
        continue
    
    young = row[1] if len(row) > 1 else None
    yield_s = row[4] if len(row) > 4 else None
    
    if young is not None and yield_s is not None:
        try:
            young = float(young) * 1000
            yield_s = float(yield_s)
            materials.append((young, yield_s))
        except (ValueError, TypeError):
            continue

output_file = "materials.txt"
with open(output_file, "w") as f:
    for young, yield_s in materials:
        f.write(f"{young} {yield_s}\n")

print(f"Generated {output_file} with {len(materials)} material sets")
