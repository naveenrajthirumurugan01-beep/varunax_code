import subprocess
import os

def convert_onnx_to_tflite():
    onnx_path = "flood_segmentation.onnx"
    
    if not os.path.exists(onnx_path):
        print(f" Error: Cannot find '{onnx_path}' in the current folder!")
        return

    print(" Starting local conversion from ONNX to TFLite...")
    
    # Run the onnx2tf command-line interface directly through Python
    # This automatically builds the float32 mobile flatbuffer structure
    try:
        subprocess.run([
            "onnx2tf",
            "-i", onnx_path,
            "-nonc"  # Optimization flag: disables checking tensor names for faster CPU generation
        ], check=True)
        
        print("\n Success! Look inside the auto-generated 'saved_model' or check for 'saved_model/flood_segmentation_float32.tflite'")
        
    except subprocess.CalledProcessError as e:
        print(f" Conversion failed with execution error: {e}")

if __name__ == "__main__":
    convert_onnx_to_tflite()