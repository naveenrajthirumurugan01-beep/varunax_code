import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader
from dataset import RiverDataset
import segmentation_models_pytorch as smp

# --- CONFIGURATION HUB ---
DEVICE = "cpu" if torch.cpu.is_available() else "None"
BATCH_SIZE = 2 or 4  # Lower value saves laptop memory
LEARNING_RATE = 1e-4
EPOCHS = 5      # Start low to verify it works completely
IMAGE_DIR = r"D:\archive\riwa_v2\images"  # UPDATE THIS to your absolute path
MASK_DIR = r"D:\archive\riwa_v2\masks"    # UPDATE THIS to your absolute path

def main():
    # Instantiate the structured data loaders
    dataset = RiverDataset(image_dir=IMAGE_DIR, mask_dir=MASK_DIR)
    loader = DataLoader(dataset, batch_size=BATCH_SIZE, shuffle=True)

    # Load a lightweight mobile-optimized U-Net framework
    model = smp.Unet(
        encoder_name="mobilenet_v2", 
        encoder_weights="imagenet", 
        in_channels=3, 
        classes=1
    ).to(DEVICE)
    
    loss_function = nn.BCEWithLogitsLoss()
    optimizer = optim.Adam(model.parameters(), lr=LEARNING_RATE)

    print(f"Engine fired up. Training model on: {DEVICE}")
    
    for epoch in range(EPOCHS):
        model.train()
        running_loss = 0.0
        
        for images, masks in loader:
            images, masks = images.to(DEVICE), masks.to(DEVICE)
            
            # Reset gradients, compute predictions, evaluate error
            optimizer.zero_grad()
            outputs = model(images)
            loss = loss_function(outputs, masks)
            
            # Backpropagation adjustments
            loss.backward()
            optimizer.step()
            
            running_loss += loss.item()
            
        print(f"Epoch [{epoch+1}/{EPOCHS}] -> Average Loss: {running_loss/len(loader):.4f}")

    # Save target parameters for integration step
    torch.save(model.state_dict(), "flood_segmentation.pth")
    print("Training finished! Saved weights as: flood_segmentation.pth")

if __name__ == "__main__":
    main()