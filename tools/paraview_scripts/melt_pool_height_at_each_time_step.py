import os
import sys
import csv

#### import the simple module from the paraview
from paraview.simple import *
from functions_for_post_processing import *


def main():
    case_directory = './'

    if len(sys.argv) == 1:
        case_type = 'Decomposed Case'
    elif sys.argv[1] == '-d':
        case_type = 'Decomposed Case'
    elif sys.argv[1] == '-r':
        case_type = 'Reconstructed Case'

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

        height  = get_height_at_laser_point(case_directory,foamfoam,'alpha.metal', time)
        data[time] = height

    with open('height_data.csv', 'w') as f:
        w = csv.writer(f)
        for item in data.items():
            if abs(item[1]) == 1. or abs(item[1]) == 2.:
                continue
            w.writerow(item)

if __name__ == '__main__':
    main()
