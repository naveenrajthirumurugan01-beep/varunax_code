import os
import cv2
import torch
from torch.utils.data import Dataset

class RiverDataset(Dataset):
    def __init__(self, image_dir, mask_dir, transform=None):
        self.image_dir = image_dir
        self.mask_dir = mask_dir
        self.transform = transform
        
        # Load all image filenames (.jpg)
        all_images = os.listdir(image_dir)
        self.valid_images = []
        
        for img_name in all_images:
            img_path = os.path.join(self.image_dir, img_name)
            
            # 🔥 FIX: Change the extension from .jpg to .png to check for the mask
            mask_name = img_name.replace(".jpg", ".png")
            mask_path = os.path.join(self.mask_dir, mask_name)
            
            # Only include if both files exist
            if os.path.exists(img_path) and os.path.exists(mask_path):
                self.valid_images.append(img_name)
            else:
                print(f"⚠️ Skipping mismatch: Image {img_name} or Mask {mask_name} missing.")

        print(f"📂 Dataset initialized. Found {len(self.valid_images)} matching image-mask pairs.")

    def __len__(self):
        return len(self.valid_images)

    def __getitem__(self, index):
        img_name = self.valid_images[index]
        img_path = os.path.join(self.image_dir, img_name)
        
        # 🔥 FIX: Generate the matching mask filename with the correct .png extension
        mask_name = img_name.replace(".jpg", ".png")
        mask_path = os.path.join(self.mask_dir, mask_name)
        
        # Load image (Convert from default BGR to RGB)
        image = cv2.imread(img_path)
        if image is None:
            raise ValueError(f"Could not read image: {img_path}")
        image = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
        
        # Load mask as grayscale
        mask = cv2.imread(mask_path, cv2.IMREAD_GRAYSCALE)
        if mask is None:
            raise ValueError(f"Could not read mask: {mask_path}")
        
        # Resize safely for CPU training efficiency
        image = cv2.resize(image, (256, 256))
        mask = cv2.resize(mask, (256, 256), interpolation=cv2.INTER_NEAREST)
        
        # Convert absolute white pixels (255) to 1.0 representation
        mask[mask == 255] = 1.0
        
        if self.transform:
            augmented = self.transform(image=image, mask=mask)
            image = augmented["image"]
            mask = augmented["mask"]
            
        # Format shapes to PyTorch standard tensors
        image = torch.tensor(image, dtype=torch.float32).permute(2, 0, 1) / 255.0
        mask = torch.tensor(mask, dtype=torch.float32).unsqueeze(0)
        
        return image, mask