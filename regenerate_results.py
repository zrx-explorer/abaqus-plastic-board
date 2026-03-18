#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Traverse res folder and collect simulation results
Usage: python regenerate_results.py /path/to/res
"""
import os
import sys
import re
import csv

def parse_result_csv(csv_path):
    """解析仿真结果 CSV，提取屈服力和截面积"""
    with open(csv_path, 'r') as f:
        first_line = f.readline().strip()
    
    # 解析注释行：# INITIAL_HEIGHT_L0=8.0000,AREA_A0=64.0000,STIFFNESS_K=1209731.2500,YIELD_FORCE_N=8134.0649
    match = re.search(r'AREA_A0=([0-9.]+)', first_line)
    area_a0 = float(match.group(1)) if match else None
    
    match = re.search(r'YIELD_FORCE_N=([0-9.]+|Not_Reached)', first_line)
    if match:
        yield_force_str = match.group(1)
        if yield_force_str == 'Not_Reached':
            yield_force = None
            yield_strength = None
        else:
            yield_force = float(yield_force_str)
            yield_strength = yield_force / area_a0 if area_a0 else None
    else:
        yield_force = None
        yield_strength = None
    
    return yield_force, yield_strength

def parse_filename(filename):
    """从文件名提取信息：stp_E{young}_Y{yield}_{direction}.csv"""
    basename = os.path.basename(filename)
    if basename.endswith('.csv'):
        basename = basename[:-4]
    
    # 匹配模式：xxx_E{young}_Y{yield}_{direction}
    match = re.match(r'(.+)_E([0-9.]+)_Y([0-9.]+)_(x|y|z)$', basename)
    if match:
        stp_file = match.group(1)
        young_module = float(match.group(2))
        yield_stress = float(match.group(3))
        direction = match.group(4)
        return stp_file, young_module, yield_stress, direction
    return None

def collect_all_results(res_dir):
    """遍历 res 目录收集所有结果"""
    results = []
    total_csv = 0
    skipped_failed = 0
    skipped_parse = 0
    skipped_read = 0
    
    for root, dirs, files in os.walk(res_dir):
        for filename in files:
            if not filename.endswith('.csv'):
                continue
            
            total_csv += 1
            
            # 跳过失败文件但计数
            if '_failed' in filename or '_timeout' in filename:
                skipped_failed += 1
                continue
            
            csv_path = os.path.join(root, filename)
            parsed = parse_filename(filename)
            
            if not parsed:
                skipped_parse += 1
                continue
            
            stp_file, young_module, yield_stress, direction = parsed
            
            try:
                yield_force, yield_strength = parse_result_csv(csv_path)
            except Exception as e:
                skipped_read += 1
                print("Warning: Cannot read {} - {}".format(filename, e))
                continue
            
            results.append({
                'stp_file': stp_file,
                'young_module': young_module,
                'yield_stress': yield_stress,
                'direction': direction,
                'yield_force': yield_force if yield_force else '',
                'yield_strength': round(yield_strength, 4) if yield_strength else ''
            })
    
    print("Total CSV files found: {}".format(total_csv))
    print("Skipped (failed/timeout): {}".format(skipped_failed))
    print("Skipped (parse failed): {}".format(skipped_parse))
    print("Skipped (read error): {}".format(skipped_read))
    print("Successfully processed: {}".format(len(results)))
    
    return results

def main():
    if len(sys.argv) < 2:
        print("Usage: python regenerate_results.py /path/to/res")
        sys.exit(1)
    
    res_dir = sys.argv[1]
    
    if not os.path.isdir(res_dir):
        print("Error: {} is not a directory".format(res_dir))
        sys.exit(1)
    
    print("Scanning: {}".format(res_dir))
    results = collect_all_results(res_dir)
    
    # Write successful results
    output_csv = os.path.join(res_dir, 'result_regenerated.csv')
    with open(output_csv, 'w') as f:
        writer = csv.writer(f)
        writer.writerow(['stp_file', 'young_module', 'yield_stress', 'direction', 'yield_force', 'yield_strength'])
        
        for row in results:
            writer.writerow([
                row['stp_file'],
                row['young_module'],
                row['yield_stress'],
                row['direction'],
                row['yield_force'],
                row['yield_strength']
            ])
    
    print("Generated {} with {} results".format(output_csv, len(results)))
    
    # Find missing results by comparing with tasks.txt and materials.txt
    script_dir = os.path.dirname(os.path.abspath(__file__))
    tasks_file = os.path.join(script_dir, 'tasks.txt')
    materials_file = os.path.join(script_dir, 'materials.txt')
    
    missing_results = []
    
    if os.path.exists(tasks_file) and os.path.exists(materials_file):
        print("\nChecking for missing results...")
        
        # Read tasks
        with open(tasks_file, 'r') as f:
            tasks = []
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    parts = line.split()
                    if len(parts) >= 2:
                        tasks.append((parts[0], parts[1]))  # (path, direction)
        
        # Read materials
        with open(materials_file, 'r') as f:
            materials = []
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    parts = line.split()
                    if len(parts) >= 2:
                        materials.append((float(parts[0]), float(parts[1])))  # (young, yield)
        
        print("Tasks: {}, Materials: {}".format(len(tasks), len(materials)))
        
        # Build set of existing results
        existing = set()
        for r in results:
            key = (r['stp_file'], r['young_module'], r['yield_stress'], r['direction'])
            existing.add(key)
        
        # Check what's missing
        for task_path, direction in tasks:
            stp_file = os.path.basename(task_path)
            if stp_file.endswith('.stp') or stp_file.endswith('.step'):
                stp_file = stp_file[:-4]
            
            for young, yield_s in materials:
                key = (stp_file, young, yield_s, direction)
                if key not in existing:
                    missing_results.append({
                        'stp_file': stp_file,
                        'young_module': young,
                        'yield_stress': yield_s,
                        'direction': direction,
                        'status': 'missing_result'
                    })
        
        # Write missing results
        if missing_results:
            missing_csv = os.path.join(res_dir, 'result_missing.csv')
            with open(missing_csv, 'w') as f:
                writer = csv.writer(f)
                writer.writerow(['stp_file', 'young_module', 'yield_stress', 'direction', 'status'])
                for row in missing_results:
                    writer.writerow([
                        row['stp_file'],
                        row['young_module'],
                        row['yield_stress'],
                        row['direction'],
                        row['status']
                    ])
            print("Generated {} with {} missing results".format(missing_csv, len(missing_results)))
        else:
            print("All expected results found!")
    
    # 统计信息
    success = sum(1 for r in results if r['yield_force'] != '')
    failed = len(results) - success
    print("\nSummary:")
    print("  Success: {}".format(success))
    print("  Failed/Empty: {}".format(failed))
    print("  Missing: {}".format(len(missing_results)))

if __name__ == '__main__':
    main()
