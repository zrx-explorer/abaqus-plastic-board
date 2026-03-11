#!/usr/bin/env python
# coding=utf-8

"""
Abaqus ODB Monitor for Cellular Structure Compression
- Extracts RF-U (Force-Displacement) from the Reference Point.
- Calculates 0.2% offset Yield Force dynamically (based on Force-Strain curve).
- Triggers early stop (Exit 0) exactly 1 increment after yield point is reached.
- Exports data to [STP_FILENAME]_E[Young]_Y[Yield].csv
- Saves AREA_A0 in metadata for user to calculate stress if needed

EXIT CODE:
    - 1 : Not yielded yet, keep computing.
    - 0 : Yield point reached + 1 extra point recorded, stop computation safely.
"""

import sys
import os
import csv
import time
import json
import odbAccess

def get_dimensions_from_odb(odb, instance_name='STRUCTURE-1'):
    """
    Dynamically extract the initial height (L0) and cross-sectional area (A0) 
    from the cell structure's bounding box inside the ODB.
    """
    try:
        inst = odb.rootAssembly.instances[instance_name]
        coords = [n.coordinates for n in inst.nodes]
        if not coords: 
            return 1.0, 1.0
            
        x_coords = [c[0] for c in coords]
        y_coords = [c[1] for c in coords]
        z_coords = [c[2] for c in coords]
        
        x_span = max(x_coords) - min(x_coords)
        y_span = max(y_coords) - min(y_coords)
        z_span = max(z_coords) - min(z_coords)
        
        A0 = x_span * y_span
        L0 = z_span
        
        if A0 <= 0 or L0 <= 0:
            return 1.0, 1.0
        return L0, A0
    except Exception as e:
        print("[Monitor Warning] Failed to get bounding box: {}".format(str(e)))
        return 1.0, 1.0

def extract_rf_u(odb, nodeSet_name='REFERENCE_POINT_PART-2-1', inst_name='PART-2-1'):
    """
    Extract Z-direction Absolute Displacement and Reaction Force from the Reference Point.
    """
    u_list = []
    rf_list = []
    
    # Normally the step is 'Step-1'
    step_name = odb.steps.keys()[0] 
    step = odb.steps[step_name]
    
    try:
        inst = odb.rootAssembly.nodeSets[nodeSet_name]
    except KeyError:
        print("[Monitor Warning] NodeSet {} not found in ODB.".format(nodeSet_name))
        return [], []
    
    # Get reference point node label
    rp_keys = inst.nodes[0]
    if len(rp_keys) == 0:
        print("[Monitor Warning] No reference points found in instance {}.".format(nodeSet_name))
        return [], []
    
    # Reference point node label (key)
    rp_node_label = rp_keys[0].label
    
    # Get all nodes in the assembly and find the reference point node
    for frame in step.frames:
        try:
            # Get RF and U field outputs for the whole assembly
            rf_field = frame.fieldOutputs['RF']
            u_field = frame.fieldOutputs['U']
            
            # Iterate through values to find the reference point
            rf_z = None
            for rf_val in rf_field.values:
                if rf_val.nodeLabel == rp_node_label and rf_val.instance.name==inst_name:
                    rf_z = abs(rf_val.data[2])  # RF3
                    
                    # Find corresponding displacement
                    for u_val in u_field.values:
                        if u_val.nodeLabel == rp_node_label:
                            u_z = abs(u_val.data[2])  # U3
                            u_list.append(u_z)
                            rf_list.append(rf_z)
                            break
                    break
        except Exception as e:
            print("[Monitor Debug] Frame read error: {}".format(str(e)))
            pass
            
    return u_list, rf_list

def calculate_yield_force(u_list, rf_list, L0):
    """
    Calculate 0.2% offset yield force (not stress). 
    Returns: Yield Force (N), Yield Index in lists, Stiffness K (N/mm)
    """
    if len(u_list) < 3:
        return None, -1, 0.0
    
    strains = [u / L0 for u in u_list]
    
    # 1. Find the Maximum Stiffness (K) in the early linear region (Force-Strain slope)
    max_K = 0.0
    for i in range(1, len(strains)):
        dstrain = strains[i] - strains[i-1]
        dforce = rf_list[i] - rf_list[i-1]
        
        if dstrain > 1e-6:
            K = dforce / dstrain
            if K > max_K:
                max_K = K
        
        # Stop looking for stiffness after 2% strain to avoid densification slope
        if strains[i] > 0.02:
            break
            
    if max_K <= 0:
        return None, -1, max_K
        
    # 2. Find the exact point where actual Force curve crosses below the 0.2% offset line
    yield_force = None
    yield_idx = -1
    
    for i in range(1, len(strains)):
        # Formula: F_offset = K * (Strain - 0.002)
        offset_force = max_K * (strains[i] - 0.002)
        
        # If theoretical offset force is positive AND actual force drops below it
        if offset_force > 0 and rf_list[i] <= offset_force:
            yield_force = rf_list[i]
            yield_idx = i
            break
            
    return yield_force, yield_idx, max_K

def main():
    print("====================================================")
    print("[{}] Start Monitor Validation".format(time.ctime()))
    
    odb_file = "Job-Compression-Run.odb"
    
    stp_filename = "Sim_Results"
    young_module_val = "28700"
    yield_stress_val = "221.0"
    direction_val = "z"
    if os.path.exists("info.json"):
        try:
            with open("info.json", "r") as f:
                info = json.load(f)
                raw_name = info.get("stp_filename", "Sim_Results")
                stp_filename = raw_name.replace(".step", "").replace(".stp", "")
                young_module_val = str(info.get("young_module", "28700"))
                yield_stress_val = str(info.get("yield_stress", "221.0"))
                direction_val = str(info.get("direction", "z"))
        except Exception:
            pass

    out_csv = stp_filename + "_E" + young_module_val + "_Y" + yield_stress_val + "_" + direction_val + ".csv"
    
    # 1. Open ODB
    if not os.path.exists(odb_file):
        print("[Monitor] {} not found yet. Keep waiting...".format(odb_file))
        sys.exit(1)
        
    try:
        odb = odbAccess.openOdb(path=odb_file, readOnly=True)
    except odbAccess.OdbError:
        print("[Monitor] ODB is currently locked/being written by Abaqus. Wait...")
        sys.exit(1)
        
    # 2. Extract Data
    L0, A0 = get_dimensions_from_odb(odb, 'STRUCTURE-1')
    u_list, rf_list = extract_rf_u(odb, 'REFERENCE_POINT_PART-2-1')
    odb.close()
    
    if len(u_list) == 0:
        print("[Monitor] No frames/data found in ODB yet.")
        sys.exit(1)
        
    # 3. Process Yield (based on Force-Strain curve)
    yield_force, yield_idx, K = calculate_yield_force(u_list, rf_list, L0)
    
    # 4. Write CSV Export (Overwrite safely)
    with open(out_csv, mode='w') as csv_file:
        writer = csv.writer(csv_file)
        
        # Write metadata header
        yield_force_str = "{:.4f}".format(yield_force) if yield_force else "Not_Reached"
        writer.writerow(["# INITIAL_HEIGHT_L0={:.4f}".format(L0), 
                         "AREA_A0={:.4f}".format(A0), 
                         "STIFFNESS_K={:.4f}".format(K), 
                         "YIELD_FORCE_N={}".format(yield_force_str)])
        
        # Write Data Columns: Force-Strain curve (user can divide by A0 later if needed)
        writer.writerow(["Displacement_U3(mm)", "ReactionForce_RF3(N)", "Strain"])
        for u, rf in zip(u_list, rf_list):
            writer.writerow([u, rf, u/L0])
            
    # 5. Determine Early Stopping
    if yield_idx != -1:
        # Check if we have successfully recorded AT LEAST 1 extra point after the yield increment
        if len(u_list) > yield_idx + 1:
            print("[Monitor] Yield point reached + 1 extra point computed. Safe to STOP.")
            sys.exit(0) # 0 triggers the external bash/python wrapper to terminate Abaqus
        else:
            print("[Monitor] Yield point reached! Waiting to compute 1 extra point...")
            sys.exit(1)
    else:
        print("[Monitor] Still in elastic phase (t_frames = {}). Continue...".format(len(u_list)))
        sys.exit(1)

if __name__ == "__main__":
    main()