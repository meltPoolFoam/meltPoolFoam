import os
import sys
import csv

#### import the simple module from the paraview
from paraview.simple import *

def main():
    case_directory = './'

    # --- Boilerplate for case type selection ---
    if len(sys.argv) == 1:
        case_type = 'Decomposed Case'
    elif sys.argv[1] == '-d':
        case_type = 'Decomposed Case'
    elif sys.argv[1] == '-r':
        case_type = 'Reconstructed Case'
    else:
        print("Unknown argument. Use '-d' for decomposed or '-r' for reconstructed.")
        return 1

    foam_file_path = None
    for filename in os.listdir(case_directory):
        if filename == 'foam.foam':
            foam_file_path = os.path.join(case_directory, filename)
            break

    if not foam_file_path:
        print('Error: foam.foam file not found in the current directory.')
        return 1

    # --- ParaView pipeline setup ---

    # Create a new 'OpenFOAMReader'
    foam_reader = OpenFOAMReader(registrationName='foam.foam', FileName=foam_file_path)
    foam_reader.CaseType = case_type

    # Select the necessary fields to reduce memory usage
    foam_reader.PointArrays = ['U', 'liquidFraction']

    foam_reader.UpdatePipelineInformation()
    time_steps = foam_reader.TimestepValues
    max_velocity_data = {}


    # --- Main loop over time steps ---
    for time in time_steps:
        # Set the pipeline to the current time step
        foam_reader.UpdatePipeline(time)

        # 1. Apply a Threshold filter
        threshold = Threshold(Input=foam_reader)
        threshold.Scalars = ['POINTS', 'liquidFraction']
        
        # --- CORRECTED THRESHOLD PROPERTIES ---
        # Instead of ThresholdRange, use LowerThreshold and UpperThreshold
        threshold.LowerThreshold = 0.5
        threshold.UpperThreshold = 1.0
        # Set the method to select values between the lower and upper bounds
        threshold.ThresholdMethod = 'Between'
        # --- END OF CORRECTION ---

        threshold.UpdatePipeline()

        # Check if the thresholded dataset is empty
        if threshold.GetDataInformation().GetNumberOfPoints() == 0:
            max_velocity_data[time] = 0.0
            continue
            
        # 2. Apply a Calculator filter
        calculator = Calculator(Input=threshold)
        calculator.ResultArrayName = 'VelocityMagnitude'
        calculator.Function = 'mag(U)'
        calculator.UpdatePipeline()

        # 3. Get the maximum value of the computed 'VelocityMagnitude'
        data_info = calculator.GetDataInformation()
        point_data_info = data_info.GetPointDataInformation()
        array_info = point_data_info.GetArrayInformation('VelocityMagnitude')
        
        if array_info:
            value_range = array_info.GetComponentRange(0)
            max_vel = value_range[1]
            max_velocity_data[time] = max_vel
        else:
            max_velocity_data[time] = 0.0


    # --- Write data to CSV file ---
    output_filename = 'Umax_data.csv'
    with open(output_filename, 'w', newline='') as f:
        writer = csv.writer(f)
        for time, max_vel in max_velocity_data.items():
            writer.writerow([time, max_vel])



if __name__ == '__main__':
    main()

