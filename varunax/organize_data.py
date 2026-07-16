import os
import shutil

# --- CONFIGURATION ---
# Point this to your unzipped archive folder containing train/validation/test
EXTRACTED_SRC = r"D:\varunax-model\varunax\your_dataset" 
# This is where your clean unified dataset will go
TARGET_DIR = r"D:\varunax-model\varunax\dataset_clean"

os.makedirs(os.path.join(TARGET_DIR, "images"), exist_ok=True)
os.makedirs(os.path.join(TARGET_DIR, "masks"), exist_ok=True)

print("Starting dataset consolidation...")

# Walk through all subfolders in your dataset
for root, dirs, files in os.walk(EXTRACTED_SRC):
    for file in files:
        if file.endswith(('.jpg', '.jpeg', '.png')):
            source_path = os.path.join(root, file)
            
            # Check if this file is part of an image folder or a mask folder
            if "images" in root.lower() or "train" in root.lower() and "masks" not in root.lower():
                shutil.copy(source_path, os.path.join(TARGET_DIR, "images", file))
            elif "masks" in root.lower():
                shutil.copy(source_path, os.path.join(TARGET_DIR, "masks", file))

print(f"Done! Check your new clean folders at: {TARGET_DIR}")
print(f"Total Images copied: {len(os.listdir(os.path.join(TARGET_DIR, 'images')))}")
print(f"Total Masks copied: {len(os.listdir(os.path.join(TARGET_DIR, 'masks')))}")