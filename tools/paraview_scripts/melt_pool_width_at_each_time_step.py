import os
import sys
import csv

#### import the simple module from the paraview
from paraview.simple import *
from functions_for_post_processing import *


def main():
    
    case_directory = './'

    axis, case_type = 'x', 'Decomposed Case'

    arg_dict_axis = {'-x':'x','-y':'y','-z':'z',}
    arg_dict_decompose = {'-d':'Decomposed Case','-r':'Reconstructed Case'}
    for arg in sys.argv[1:]:
        if arg in arg_dict_axis:
            axis = arg_dict_axis[arg]
        if arg in arg_dict_decompose:
            case_type = arg_dict_decompose[arg]


    for filename in os.listdir(case_directory):
        if filename == 'foam.foam':
            foam_file_path = os.path.join(case_directory, filename)

    if not foam_file_path:
        print('No foam.foam file found')
        return 0

    # create a new 'OpenFOAMReader'
    foamfoam = OpenFOAMReader(registrationName='foam.foam', FileName=foam_file_path)
    foamfoam.CaseType = case_type
    foamfoam.UpdatePipelineInformation()
    time_steps = foamfoam.TimestepValues
    data = {}

    for time in time_steps:

        xmin,xmax,ymin,ymax,zmin,zmax = get_bounds_of_countour(foamfoam,'liquidFraction',time)
        if  axis == 'x':
            width = xmax - xmin
        elif axis == 'y':
            width = ymax - ymin
        else:
            width = zmax - zmin
        data[time] = width

    with open('width_data.csv', 'w') as f:
        w = csv.writer(f)
        for item in data.items():
            if abs(item[1]) == 1. or abs(item[1]) == 2.:
                continue
            w.writerow(item)

if __name__ == '__main__':
    main()
