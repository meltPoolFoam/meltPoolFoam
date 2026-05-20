import os
import sys
import gc

#### import the simple module from the paraview
from paraview.simple import *

#### assisting functions
def get_value_from_dict(case_directory,dictionary_of_propertie_location,propertie_name,parameter_place=-1):
    dict_location = os.path.join(case_directory,dictionary_of_propertie_location)
    value = None
    with open(dict_location,"r") as file:
        for line in file.readlines():
            if propertie_name in line:
                value = line.split()[parameter_place].strip(';')
                break
    return value

#### paraview functions
def get_bounds_of_countour(source,field_name,time,iso_surface_value=0.500001):
    # create a new 'Contour'
    contour_for_bounds = Contour(registrationName='Contour', Input=source)
    contour_for_bounds.ContourBy = ['POINTS', field_name]
    contour_for_bounds.Isosurfaces = [iso_surface_value]
    UpdatePipeline(time=time, proxy=contour_for_bounds)
    return contour_for_bounds.GetDataInformation().GetBounds()

def get_isosurface_z_at_xy(source, field_name, time, x, y,
                           z_min_bound=-1.0, z_max_bound=1.0,
                           iso_value=0.500001, resolution=500):
    """
    Returns (z_min, z_max) where field_name == iso_value
    at position (x, y), by sampling along a vertical line.
    Uses PlotOverLine — lightweight, no mesh extraction.
    """
    DEBUG = False

    # 1. Sample along a vertical line at (x, y)
    line = PlotOverLine(registrationName='ZProbe', Input=source)
    line.Point1 = [x, y, z_min_bound]
    line.Point2 = [x, y, z_max_bound]
    line.Resolution = resolution

    if DEBUG: print(f"  PlotOverLine at x={x:.6e}, y={y:.6e}, z=[{z_min_bound}, {z_max_bound}]")
    UpdatePipeline(time=time, proxy=line)

    # 2. Fetch the sampled data locally
    data = servermanager.Fetch(line)
    alpha = data.GetPointData().GetArray(field_name)
    coords = data.GetPoints()
    n = data.GetNumberOfPoints()

    if alpha is None or n == 0:
        if DEBUG: print(f"  WARNING: {field_name} not found or no points sampled")
        Delete(line)
        return None, None

    # 3. Find all z-crossings where field crosses iso_value
    z_crossings = []
    for i in range(n - 1):
        a0 = alpha.GetValue(i)
        a1 = alpha.GetValue(i + 1)

        if (a0 - iso_value) * (a1 - iso_value) <= 0:
            z0 = coords.GetPoint(i)[2]
            z1 = coords.GetPoint(i + 1)[2]
            # Linear interpolation
            denom = a1 - a0
            frac = (iso_value - a0) / denom if denom != 0 else 0.5
            z_crossings.append(z0 + frac * (z1 - z0))

    Delete(line)
    del line

    if not z_crossings:
        if DEBUG: print(f"  WARNING: No crossing found")
        return None, None

    if DEBUG: print(f"  Found {len(z_crossings)} crossing(s): z_min={min(z_crossings):.6e}, z_max={max(z_crossings):.6e}")
    return min(z_crossings), max(z_crossings)

def _get_laser_x_coordinate(case_directory, time):
    """Helper to compute x-coordinate of laser center at given time."""
    laser_start_point = float(get_value_from_dict(case_directory, 'constant/laserProperties', 'coordStart', parameter_place=-4))
    laser_velocity = float(get_value_from_dict(case_directory, 'constant/laserProperties', 'velocity', parameter_place=-4))
    laser_stop_time = float(get_value_from_dict(case_directory, 'constant/laserProperties', 'timeStop'))
    beam_radius = float(get_value_from_dict(case_directory, 'constant/laserProperties', 'radius'))
    adaptive_frame_type = get_value_from_dict(case_directory, 'system/movingFrameDict', 'type', parameter_place=-5)

    x_center = laser_start_point + laser_velocity * (laser_stop_time if time > laser_stop_time else time)
    if adaptive_frame_type == 'given':
        x_center = laser_start_point - laser_velocity * ((time - laser_stop_time) if time > laser_stop_time else 0)

    return x_center, beam_radius


def get_surface_depression_at_laser_point(case_directory, source, field_name, time, iso_surface_value=0.500001):
    DEBUG = False

    x_center, beam_radius = _get_laser_x_coordinate(case_directory, time)
    y_coordinate = 0.0

    if DEBUG: print(f"Time = {time}")
    if DEBUG: print(f"x_center_coordinate = {x_center*1e6:.1f}")
    if DEBUG: print("-" * 10)

    # Update source at this timestep
    UpdatePipeline(time=time, proxy=source)

    # Sample along z at the laser center
    z_min, z_max = get_isosurface_z_at_xy(
        source, field_name, time,
        x=x_center, y=y_coordinate,
        z_min_bound=-0.001, z_max_bound=0.001,  # adjust to your domain
        iso_value=iso_surface_value
    )

    if z_min is None:
        if DEBUG: print(f"  No surface found at time {time}")
        gc.collect()
        return None

    if DEBUG: print(f"z_min = {z_min*1e6:.2f}, z_max = {z_max*1e6:.2f}")

    depression = z_min

    if DEBUG: print(f"Height at {time} = {depression}")
    if DEBUG: print("-" * 10)

    gc.collect()
    return depression


def get_height_at_laser_point(case_directory,source,field_name,time,iso_surface_value=0.500001):
    DEBUG = False
    # get values from dicts for location of the along line
    laser_start_point = float(get_value_from_dict(case_directory,'constant/laserProperties','coordStart',parameter_place=-4))
    laser_velocity = float(get_value_from_dict(case_directory,'constant/laserProperties','velocity',parameter_place=-4))
    laser_stop_time = float(get_value_from_dict(case_directory,'constant/laserProperties','timeStop'))
    beam_radius = float(get_value_from_dict(case_directory,'constant/laserProperties','radius'))

    adaptive_frame_type = get_value_from_dict(case_directory,'system/movingFrameDict','type',parameter_place=-5) 

    # exctractCells at center of the beam
    # assumption that beam moves along x axis at y=0
    x_center_coordinate = laser_start_point + laser_velocity*(laser_stop_time if  time > laser_stop_time else time)
    if adaptive_frame_type == 'given':
        x_center_coordinate = laser_start_point - laser_velocity*((time - laser_stop_time) if  time > laser_stop_time else 0)
    
    y_coordinate = 0.0
    z_coordinate = 1.0
    # 1. Go line scan around center in the melt pool region difine map and define topogrpaphy by evaluation of gradient and curvature
    #    search by line in the area of melt pool along x. 1) Definte if surface is convex or concave by comparison of values at (x+d_l),
    #    (x-d_l).
    # 2. Search along line at (x-d_l), (x+d_l) take 10 points, check if maximum or minimum value is greater. Choose the greater.
    # Comments: (1) Is good but diffucult to implement, (2) easy to implement but not robust fos small scales.
    if DEBUG == True: print(f"Time = {time}")
    if DEBUG == True: print(f"x_center_coordinate = {x_center_coordinate*1e6:.1f}")
    if DEBUG == True: print("-"*10)
    NUMBER_OF_POINTS = 6
    list_of_z_points_mins = []
    list_of_z_points_maxs = []
    list_of_z_points_avs = []
    for i in range(NUMBER_OF_POINTS):
        x_coordinate = x_center_coordinate - 0.08*beam_radius -  (0.3)*i*beam_radius/NUMBER_OF_POINTS
        extractCellsAlongLine = ExtractCellsAlongLine(registrationName='ExtractCellsAlongLine', Input=source)
        extractCellsAlongLine.Point1 = [x_coordinate, y_coordinate, -z_coordinate]
        extractCellsAlongLine.Point2 = [x_coordinate, y_coordinate, z_coordinate]
        # exctractSurface and get bounds
        _,_,_,_,z_min,z_max = get_bounds_of_countour(extractCellsAlongLine,field_name,time,iso_surface_value=iso_surface_value)
        list_of_z_points_mins.append(z_min)
        list_of_z_points_maxs.append(z_max)
        list_of_z_points_avs.append((z_min + z_max)/2.)

        if DEBUG == True: print(f"z_min = {z_min*1e6:.2f}, z_max = {z_max*1e6:.2f}, z_av = {1e6*(z_min + z_max)/2:.2f}, x_coordinate = {(x_coordinate - x_center_coordinate)*1e6:.1f}")
    
    for i in range(1, len(list_of_z_points_avs) - 1):
        
        diff_prev = list_of_z_points_avs[i] - list_of_z_points_avs[i-1]
        diff_next = list_of_z_points_avs[i+1] - list_of_z_points_avs[i]

        if (diff_prev * diff_next == 0):
            break

        sign_prev = diff_prev/abs(diff_prev)
        sign_next = diff_next/abs(diff_next)
        if DEBUG == True: print(sign_prev, sign_next)
        if sign_prev != sign_next:
            if DEBUG == True: print(list_of_z_points_avs[i])
            break
    
    height = list_of_z_points_avs[i]
    
    # height = max(list_of_z_points_maxs) if (abs(max(list_of_z_points_maxs)) > abs(min(list_of_z_points_mins))) else min(list_of_z_points_mins)
    if DEBUG == True: print(f"Height at {time} = {height}")
    if DEBUG == True: print("-"*10)
    # average the results
    return height
