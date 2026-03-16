#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Check specific STP structures in res folder
Usage: python check_missing_structures.py /path/to/res
"""
import os
import sys
import re

def find_structure_csv(res_dir, structure_name):
    """Find all CSV files for a specific structure"""
    found_files = []
    
    for root, dirs, files in os.walk(res_dir):
        for filename in files:
            if not filename.endswith('.csv'):
                continue
            if filename.startswith(structure_name):
                csv_path = os.path.join(root, filename)
                found_files.append(csv_path)
    
    return found_files

def parse_csv_header(csv_path):
    """Parse CSV header to extract YIELD_FORCE_N and AREA_A0"""
    try:
        with open(csv_path, 'r') as f:
            first_line = f.readline().strip()
        
        if not first_line.startswith('#'):
            return None, "First line is not a comment"
        
        # Extract values
        area_match = re.search(r'AREA_A0=([0-9.]+)', first_line)
        yield_match = re.search(r'YIELD_FORCE_N=([0-9.]+|Not_Reached)', first_line)
        
        result = {}
        if area_match:
            result['AREA_A0'] = area_match.group(1)
        if yield_match:
            result['YIELD_FORCE_N'] = yield_match.group(1)
        
        return result, None
    except Exception as e:
        return None, str(e)

def main():
    if len(sys.argv) < 2:
        print("Usage: python check_missing_structures.py /path/to/res")
        sys.exit(1)
    
    res_dir = sys.argv[1]
    
    # List of structures to check
    structures_to_check = [
        'Array_3x3x3_S4_D10_00_06_06',
        'Array_3x3x3_S4_D10_06_00_06',
        'Array_3x3x3_S4_D12_00_06_06',
        'Array_3x3x3_S4_D12_04_12_00',
        'Array_3x3x3_S4_D12_06_00_06',
        'Array_3x3x3_S4_D8_06_00_06',
    ]
    
    print("Checking structures in: {}".format(res_dir))
    print("=" * 80)
    
    total_found = 0
    total_valid = 0
    
    for structure in structures_to_check:
        print("\nStructure: {}".format(structure))
        print("-" * 60)
        
        files = find_structure_csv(res_dir, structure)
        
        if not files:
            print("  No CSV files found!")
            continue
        
        total_found += len(files)
        
        for csv_path in files:
            filename = os.path.basename(csv_path)
            print("\n  File: {}".format(filename))
            
            # Try to parse filename
            basename = filename[:-4] if filename.endswith('.csv') else filename
            match = re.match(r'(.+)_E([0-9.]+)_Y([0-9.]+)_(x|y|z)$', basename)
            
            if match:
                stp_file = match.group(1)
                young = match.group(2)
                yield_s = match.group(3)
                direction = match.group(4)
                print("    Filename parsed: OK")
                print("    - STP: {}, E: {}, Y: {}, Dir: {}".format(stp_file, young, yield_s, direction))
            else:
                print("    Filename parsed: FAILED")
                print("    - Basename: {}".format(basename))
                continue
            
            # Try to parse header
            data, error = parse_csv_header(csv_path)
            if error:
                print("    Header parsed: FAILED - {}".format(error))
                continue
            
            if data:
                print("    Header parsed: OK")
                if 'AREA_A0' in data:
                    print("    - AREA_A0: {}".format(data['AREA_A0']))
                if 'YIELD_FORCE_N' in data:
                    print("    - YIELD_FORCE_N: {}".format(data['YIELD_FORCE_N']))
                
                # Calculate yield strength
                if 'AREA_A0' in data and 'YIELD_FORCE_N' in data and data['YIELD_FORCE_N'] != 'Not_Reached':
                    try:
                        yield_force = float(data['YIELD_FORCE_N'])
                        area = float(data['AREA_A0'])
                        yield_strength = yield_force / area
                        print("    - Yield Strength: {:.4f} MPa".format(yield_strength))
                        total_valid += 1
                    except:
                        print("    - Yield Strength: Cannot calculate")
            else:
                print("    Header parsed: FAILED - No data")
    
    print("\n" + "=" * 80)
    print("Summary:")
    print("  Total files found: {}".format(total_found))
    print("  Total valid (with yield data): {}".format(total_valid))

if __name__ == '__main__':
    main()
