import os

IMAGE_DIR = r"D:\varunax-model\varunax\your_dataset\images"
MASK_DIR = r"D:\varunax-model\varunax\your_dataset\masks"

try:
    img_files = os.listdir(IMAGE_DIR)
    mask_files = os.listdir(MASK_DIR)

    print("--- DATASET SNEAK PEEK ---")
    print(f"Total files in images folder: {len(img_files)}")
    print(f"Total files in masks folder: {len(mask_files)}")
    
    if len(img_files) > 0:
        print(f"\nFirst 3 Image files: {img_files[:3]}")
    if len(mask_files) > 0:
        print(f"First 3 Mask files: {mask_files[:3]}")
        
except Exception as e:
    print(f"Error accessing directories: {e}")