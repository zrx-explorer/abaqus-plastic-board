# -*- coding: mbcs -*-
from abaqus import *
from abaqusConstants import *
import __main__
import section
import regionToolset
import displayGroupMdbToolset as dgm
import part
import material
import assembly
import step
import interaction
import load
import optimization
import job
import sketch
import visualization
import xyPlot
import displayGroupOdbToolset as dgo
import connectorBehavior
import mesh
import time
import os

def import_stp(file_path, model_name='Model-1'):
    model = mdb.models[model_name]
    step_file = mdb.openStep(file_path, scaleFromFile=OFF)
    model.PartFromGeometryFile(name='structure', geometryFile=step_file, 
                               combine=False, dimensionality=THREE_D, type=DEFORMABLE_BODY)
    part = model.parts['structure']

    coords = [v.pointOn[0] for v in part.vertices]
    x_min = min(c[0] for c in coords)
    x_max = max(c[0] for c in coords)
    y_min = min(c[1] for c in coords)
    y_max = max(c[1] for c in coords)
    z_min = min(c[2] for c in coords)
    z_max = max(c[2] for c in coords)
    
    return x_min, x_max, y_min, y_max, z_min, z_max

def create_board(x_min, x_max, y_min, y_max, model_name='Model-1'):
    model = mdb.models[model_name]
    sketch = model.ConstrainedSketch(name='__profile__', sheetSize=200.0)
    sketch.setPrimaryObject(option=STANDALONE)
    sketch.rectangle(point1=(x_min-1, y_min-1), point2=(x_max+1, y_max+1))
    
    part = model.Part(name='Part-2', dimensionality=THREE_D, type=DISCRETE_RIGID_SURFACE)
    part.BaseSolidExtrude(sketch=sketch, depth=1.0)
    sketch.unsetPrimaryObject()
    del model.sketches['__profile__']

    # Convert to shell by removing the solid cell
    part.RemoveCells(cellList=part.cells[0:1]) 
    rp = part.ReferencePoint(point=(x_max+1, y_max+1, 0.0))

    part.seedPart(size=1.0, deviationFactor=0.1, minSizeFactor=0.1)
    part.generateMesh()

def set_material(rou, young_module, poisson_ration, yield_stress, model_name='Model-1'):
    model = mdb.models[model_name]
    mat = model.Material(name='Material-1')
    mat.Density(table=((rou, ), ))
    mat.Elastic(table=((young_module, poisson_ration), ))
    mat.Plastic(scaleStress=None, table=((yield_stress, 0.0), (yield_stress, 1.0)))
    # Apply perfect elastic—plastic model
    
    model.HomogeneousSolidSection(name='Section-1', material='Material-1', thickness=None)
    part = model.parts['structure']
    cells = part.cells.getSequenceFromMask(mask=('[#1 ]', ), )
    region = part.Set(cells=cells, name='all')
    part.SectionAssignment(region=region, sectionName='Section-1', offset=0.0, 
                           offsetType=MIDDLE_SURFACE, offsetField='', 
                           thicknessAssignment=FROM_SECTION)

def set_mesh(model_name='Model-1'):
    model = mdb.models[model_name]
    part = model.parts['structure']
    cells = part.cells.getSequenceFromMask(mask=('[#1 ]', ), )
    
    part.setMeshControls(regions=cells, elemShape=TET, technique=FREE)
    # Kept only the final standard element assignments to avoid redundant overriding
    elem_type_3 = mesh.ElemType(elemCode=C3D4, elemLibrary=STANDARD, 
                                secondOrderAccuracy=OFF, distortionControl=DEFAULT)
    pickedRegions =(cells, )                            
    part.setElementType(regions=pickedRegions, elemTypes=(elem_type_3, ))
    part.seedPart(size=0.5, deviationFactor=0.1, minSizeFactor=0.01)
    part.generateMesh()

def set_steps(model_name='Model-1'):
    model = mdb.models[model_name]
    if 'Step-1' not in model.steps.keys():
        model.StaticStep(name='Step-1', previous='Initial', 
                         maxNumInc=10000, initialInc=0.02, maxInc=0.06, nlgeom=ON)
    
    model.fieldOutputRequests['F-Output-1'].setValues(timeInterval=0.01)

def set_instances(bot_movement, top_movement, model_name='Model-1'):
    root = mdb.models[model_name].rootAssembly
    root.DatumCsysByDefault(CARTESIAN)
    
    part_board = mdb.models[model_name].parts['Part-2']
    part_structure = mdb.models[model_name].parts['structure']
    
    root.Instance(name='structure-1', part=part_structure, dependent=ON)
    root.Instance(name='Part-2-1', part=part_board, dependent=ON)
    root.Instance(name='Part-2-2', part=part_board, dependent=ON)

    root.translate(instanceList=('Part-2-1', ), vector=top_movement)
    root.translate(instanceList=('Part-2-2', ), vector=bot_movement)
    
    # Create Assembly-level set for reference point (for monitor.py to extract RF-U)
    inst_board_top = root.instances['Part-2-1']
    r1 = inst_board_top.referencePoints
    rp_key = r1.keys()[0]
    root.Set(name='REFERENCE_POINT_PART-2-1', referencePoints=(r1[rp_key], ))

def set_contact(secondary_inst_name, main_inst_name, axis, location, model_name, tol=1e-4):
    model = mdb.models[model_name]
    root = model.rootAssembly

    inst_main = root.instances[main_inst_name]
    inst_sec = root.instances[secondary_inst_name]

    search_box = {
        'xMin': -99999.0, 'xMax': 99999.0,
        'yMin': -99999.0, 'yMax': 99999.0,
        'zMin': -99999.0, 'zMax': 99999.0
    }
    search_box[axis + 'Min'] = location - tol
    search_box[axis + 'Max'] = location + tol

    faces_main = inst_main.faces.getByBoundingBox(**search_box)
    faces_sec = inst_sec.faces.getByBoundingBox(**search_box)

    if not faces_main or not faces_sec:
        print("Warning: Insufficient surfaces found at {}={}. Check model position.".format(axis, location))
        return

    surf_main_name = 'Surf-Main-{}-{}'.format(main_inst_name, int(location))
    surf_sec_name = 'Surf-Sec-{}-{}'.format(secondary_inst_name, int(location))
    
    surf_main = root.Surface(side1Faces=faces_main, name=surf_main_name)
    surf_sec = root.Surface(side1Faces=faces_sec, name=surf_sec_name)

    prop_name = 'Prop-Std-Fric-0_2'
    if prop_name not in model.interactionProperties.keys():
        contact_prop = model.ContactProperty(name=prop_name)
        contact_prop.NormalBehavior(pressureOverclosure=HARD, allowSeparation=ON)
        contact_prop.TangentialBehavior(formulation=PENALTY, directionality=ISOTROPIC, 
                                        table=((0.2, ), ), fraction=0.005)

    contact_name = 'Contact-{}-{}-Std'.format(axis, int(location))
    if contact_name not in model.interactions.keys():
        model.SurfaceToSurfaceContactStd(
            name=contact_name, createStepName='Initial', 
            main=surf_main, secondary=surf_sec, 
            sliding=FINITE, interactionProperty=prop_name,
            thickness=ON, adjustMethod=NONE
        )
    print("Contact established for {} at {}={}".format(contact_name, axis, location))

def set_bcs(top_board_name, bot_board_name, axis, top_loc, bot_loc, tol=1e-4, model_name='Model-1'):
    model = mdb.models[model_name]
    root = model.rootAssembly

    inst_top = root.instances[top_board_name]
    inst_bot = root.instances[bot_board_name]

    # Target Top Box
    box_top = {'xMin': -99999.0, 'xMax': 99999.0, 'yMin': -99999.0, 'yMax': 99999.0, 'zMin': -99999.0, 'zMax': 99999.0}
    box_top[axis + 'Min'] = top_loc - tol
    box_top[axis + 'Max'] = top_loc + tol   
    faces_top = inst_top.faces.getByBoundingBox(**box_top)

    if not faces_top:
        print("Error: Top surface not found!")
        return
    region_top = root.Set(faces=faces_top, name='Set-Top-Load')

    # Target Bottom Box
    box_bot = {'xMin': -99999.0, 'xMax': 99999.0, 'yMin': -99999.0, 'yMax': 99999.0, 'zMin': -99999.0, 'zMax': 99999.0}
    box_bot[axis + 'Min'] = bot_loc - tol
    box_bot[axis + 'Max'] = bot_loc + tol   
    faces_bot = inst_bot.faces.getByBoundingBox(**box_bot)
    
    if not faces_bot:
        print("Error: Bottom surface not found!")
        return
    region_bot = root.Set(faces=faces_bot, name='Set-Bottom-Fixed')

    step_name = 'Step-1'
    if step_name not in model.steps.keys():
        model.StaticStep(name=step_name, previous='Initial', description='Static compression')

    if 'BC-Disp-Top' not in model.boundaryConditions.keys():
        model.DisplacementBC(
            name='BC-Disp-Top', createStepName=step_name, region=region_top, 
            u1=0, u2=0, u3=-0.4, ur1=0, ur2=0, ur3=0
        )

    if 'BC-Fixed-Bottom' not in model.boundaryConditions.keys():
        model.EncastreBC(name='BC-Fixed-Bottom', createStepName='Initial', region=region_bot)
        
    print("Boundary conditions applied successfully.")

def submit_job(model_name='Model-1', job_name='Job-Compression-Run', num_cpu=1):
    if job_name in mdb.jobs.keys():
        del mdb.jobs[job_name]
        print("Existing job '{}' has been deleted.".format(job_name))
        
    mdb.Job(name=job_name, model=model_name, description='', type=ANALYSIS, 
        atTime=None, waitMinutes=0, waitHours=0, queue=None, memory=90, 
        memoryUnits=PERCENTAGE, getMemoryFromAnalysis=True, 
        explicitPrecision=SINGLE, nodalOutputPrecision=SINGLE, echoPrint=OFF, 
        modelPrint=OFF, contactPrint=OFF, historyPrint=OFF, userSubroutine='', 
        scratch='', resultsFormat=ODB, numThreadsPerMpiProcess=1, 
        multiprocessingMode=DEFAULT, numCpus=num_cpu, numGPUs=num_cpu)    
    print("Job '{}' created successfully with {} CPU(s).".format(job_name, num_cpu))
    
    try:
        mdb.jobs[job_name].submit(consistencyChecking=OFF)
        print("Job '{}' has been submitted successfully.".format(job_name))
        print("{} Solving...".format(time.ctime()))
    except Exception as e:
        print("Error occurred while submitting the job: {}".format(str(e)))

# ==========================================
# Main Execution Block
# ==========================================
if __name__ == '__main__':
    import sys
    
    FILE_PATH = os.environ.get('PLASIM_INFILE', r'E:\workspace\20260302plas-contact\debug\Array_2x2x2_S4_D8_00_00_02.step')
    MODEL_NAME = 'Model-1'
    direction = os.environ.get('PLASIM_DIRECTION', 'z')
    rou = float(os.environ.get('PLASIM_ROU', '2.7e-09'))
    young_module = float(os.environ.get('PLASIM_YOUNG_MODULE', '28700'))
    poisson_ration = float(os.environ.get('PLASIM_POISSON_RATIO', '0.3'))
    yield_stress = float(os.environ.get('PLASIM_YIELD_STRESS', '221.0'))
    ncpus = int(os.environ.get('PLASIM_NCPUS', '1'))
    
    # Abaqus will work in current directory (already set by run-plastic-board.sh)
    print("Working directory: {}".format(os.getcwd()))
    
    x1, x2, y1, y2, z1, z2 = import_stp(FILE_PATH, MODEL_NAME)
    create_board(x1, x2, y1, y2, MODEL_NAME)
    set_material(rou, young_module, poisson_ration, yield_stress, MODEL_NAME)
    set_mesh(MODEL_NAME)
    set_steps(MODEL_NAME)
    if direction == 'x':
        bot_movement = (x1 - 1, 0.0, 0.0)
        top_movement = (x2, 0.0, 0.0)
        max_length=x2
        min_length=x1
    elif direction == 'y':
        bot_movement = (0.0, y1 - 1, 0.0)
        top_movement = (0.0, y2, 0.0)
        max_length=y2
        min_length=y1        
    elif direction == 'z':
        bot_movement = (0.0, 0.0, z1 - 1)
        top_movement = (0.0, 0.0, z2)
        max_length=z2
        min_length=z1        
    else:
        raise ValueError("Invalid direction parameter. Must be 'x', 'y', or 'z'.")
    set_instances(bot_movement, top_movement, MODEL_NAME)
    
    # Setup contacts and boundaries based on previous geometry logic
    print(direction, max_length, min_length)

    set_contact('structure-1', 'Part-2-1', direction, max_length, model_name=MODEL_NAME)

    set_contact('structure-1', 'Part-2-2', direction, min_length, model_name=MODEL_NAME) # Corrected to match your instance translation
    set_bcs('Part-2-1', 'Part-2-2', direction, max_length, min_length-1, model_name=MODEL_NAME)
    
    # Submit the analysis
    submit_job(model_name=MODEL_NAME, num_cpu=ncpus)