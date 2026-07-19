import os
import glob
import sys
import subprocess

# --- Auto-install dependencies if missing ---
def install_dependencies():
    print("Verifying compatible package versions...")
    try:
        # Force numpy < 2.0.0, compatible tifffile, compatible ml_dtypes, and compatible onnx
        subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "numpy<2.0.0", "tifffile<2024.8.10", "ml_dtypes<0.5.0", "onnx<=1.16.2"])
    except Exception as e:
        print(f"Warning during package verification: {e}")

    required = ["numpy", "tifffile", "torch", "torchvision", "onnx"]
    for pkg in required:
        try:
            __import__(pkg)
        except ImportError:
            print(f"Installing {pkg}...")
            subprocess.check_call([sys.executable, "-m", "pip", "install", pkg])

install_dependencies()

import numpy as np
import tifffile
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader
import torch.nn.functional as F

# --- Device configuration ---
device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
print(f"Training will run on device: {device}")

# --- Dataset Class ---
class Sen1FloodsDataset(Dataset):
    def __init__(self, img_dir, label_dir, target_size=(256, 256)):
        self.img_paths = sorted(glob.glob(os.path.join(img_dir, "*.tif")))
        self.label_paths = sorted(glob.glob(os.path.join(label_dir, "*.tif")))
        self.target_size = target_size

        assert len(self.img_paths) == len(self.label_paths), "Mismatch between images and labels count!"
        print(f"Loaded {len(self.img_paths)} satellite image-label pairs.")

    def __len__(self):
        return len(self.img_paths)

    def __getitem__(self, idx):
        # Load multiband image and label mask
        # Sen1Floods11 images are typically (512, 512, channels)
        img = tifffile.imread(self.img_paths[idx])
        label = tifffile.imread(self.label_paths[idx])

        # Handle channels. Sen1Floods11 has VV and VH in the first 2 bands.
        # Let's extract the first 2 channels (VV and VH) which are standard for SAR water detection
        if len(img.shape) == 3:
            img = img[:, :, :2]  # Keep VV & VH bands
        else:
            # Fallback if image is 2D
            img = np.stack([img, img], axis=-1)

        # Transpose to Channel-First: (H, W, C) -> (C, H, W)
        img = img.transpose(2, 0, 1).astype(np.float32)

        # Resize to structural dimension (256, 256)
        img_tensor = torch.tensor(img)
        img_tensor = F.interpolate(img_tensor.unsqueeze(0), size=self.target_size, mode='bilinear', align_corners=False).squeeze(0)

        # Preprocessing: simple clip and min-max normalization for SAR backscatter values
        img_tensor = torch.clamp(img_tensor, -30.0, 0.0)  # Standard dB backscatter ranges
        img_tensor = (img_tensor - (-30.0)) / 30.0        # Normalize to [0.0, 1.0]

        # Process label: convert label to single-channel binary mask (1 = water, 0 = non-water, -1 = ignore/no-data)
        # In Sen1Floods11, 1 is water, 0/ -1 is land/no-data.
        label = (label == 1).astype(np.float32)
        label_tensor = torch.tensor(label).unsqueeze(0).unsqueeze(0)  # Shape (1, 1, H, W)
        label_tensor = F.interpolate(label_tensor, size=self.target_size, mode='nearest').squeeze(0)

        return img_tensor, label_tensor

# --- Double Conv Block for U-Net ---
class DoubleConv(nn.Module):
    def __init__(self, in_ch, out_ch):
        super().__init__()
        self.conv = nn.Sequential(
            nn.Conv2d(in_ch, out_ch, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(out_ch),
            nn.ReLU(inplace=True),
            nn.Conv2d(out_ch, out_ch, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(out_ch),
            nn.ReLU(inplace=True)
        )

    def forward(self, x):
        return self.conv(x)

# --- Simple U-Net Architecture ---
class SatelliteUNet(nn.Module):
    def __init__(self, in_channels=2, out_channels=1):
        super().__init__()
        self.inc = DoubleConv(in_channels, 32)
        self.down1 = nn.Sequential(nn.MaxPool2d(2), DoubleConv(32, 64))
        self.down2 = nn.Sequential(nn.MaxPool2d(2), DoubleConv(64, 128))
        self.down3 = nn.Sequential(nn.MaxPool2d(2), DoubleConv(128, 256))

        self.up1 = nn.ConvTranspose2d(256, 128, kernel_size=2, stride=2)
        self.conv_up1 = DoubleConv(256, 128)
        self.up2 = nn.ConvTranspose2d(128, 64, kernel_size=2, stride=2)
        self.conv_up2 = DoubleConv(128, 64)
        self.up3 = nn.ConvTranspose2d(64, 32, kernel_size=2, stride=2)
        self.conv_up3 = DoubleConv(64, 32)

        self.outc = nn.Conv2d(32, out_channels, kernel_size=1)

    def forward(self, x):
        x1 = self.inc(x)
        x2 = self.down1(x1)
        x3 = self.down2(x2)
        x4 = self.down3(x3)

        x = self.up1(x4)
        x = torch.cat([x, x3], dim=1)
        x = self.conv_up1(x)

        x = self.up2(x)
        x = torch.cat([x, x2], dim=1)
        x = self.conv_up2(x)

        x = self.up3(x)
        x = torch.cat([x, x1], dim=1)
        x = self.conv_up3(x)

        return torch.sigmoid(self.outc(x))

# --- Main Training Script ---
if __name__ == "__main__":
    img_dir = os.path.join(os.path.dirname(__file__), "Sen1Floods11_8Channel", "image")
    label_dir = os.path.join(os.path.dirname(__file__), "Sen1Floods11_8Channel", "label")

    # Load dataset & dataloader
    dataset = Sen1FloodsDataset(img_dir, label_dir)
    train_size = int(0.85 * len(dataset))
    val_size = len(dataset) - train_size
    train_dataset, val_dataset = torch.utils.data.random_split(dataset, [train_size, val_size])

    train_loader = DataLoader(train_dataset, batch_size=8, shuffle=True)
    val_loader = DataLoader(val_dataset, batch_size=8, shuffle=False)

    model = SatelliteUNet(in_channels=2, out_channels=1).to(device)
    optimizer = optim.Adam(model.parameters(), lr=1e-3)
    criterion = nn.BCELoss()

    # Training Loop
    epochs = 10
    print("Starting training loop...")
    for epoch in range(1, epochs + 1):
        model.train()
        train_loss = 0.0
        for images, labels in train_loader:
            images, labels = images.to(device), labels.to(device)

            optimizer.zero_grad()
            outputs = model(images)
            loss = criterion(outputs, labels)
            loss.backward()
            optimizer.step()
            train_loss += loss.item() * images.size(0)

        train_loss /= len(train_dataset)

        # Validation
        model.eval()
        val_loss = 0.0
        with torch.no_grad():
            for images, labels in val_loader:
                images, labels = images.to(device), labels.to(device)
                outputs = model(images)
                loss = criterion(outputs, labels)
                val_loss += loss.item() * images.size(0)
        val_loss /= len(val_dataset)

        print(f"Epoch {epoch}/{epochs} | Train Loss: {train_loss:.4f} | Val Loss: {val_loss:.4f}")

    # --- Save PyTorch Weights ---
    weights_path = os.path.join(os.path.dirname(__file__), "satellite_unet.pth")
    torch.save(model.state_dict(), weights_path)
    print(f"Model weights saved to {weights_path}")

    # --- Export to ONNX ---
    onnx_path = os.path.join(os.path.dirname(__file__), "satellite_flood_segmentation.onnx")
    dummy_input = torch.randn(1, 2, 256, 256).to(device)
    torch.onnx.export(
        model,
        dummy_input,
        onnx_path,
        input_names=["input"],
        output_names=["output"],
        dynamic_axes={"input": {0: "batch_size"}, "output": {0: "batch_size"}},
        opset_version=11
    )
    print(f"ONNX Model exported successfully to {onnx_path}")
