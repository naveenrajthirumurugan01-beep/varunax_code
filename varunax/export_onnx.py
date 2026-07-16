import torch
import segmentation_models_pytorch as smp

# 1. Recreate the empty model blueprint
model = smp.Unet(
    encoder_name="mobilenet_v2", 
    encoder_weights=None, 
    in_channels=3, 
    classes=1
)

# 2. Load the weights your laptop is currently training
model.load_state_dict(torch.load("flood_segmentation.pth", map_location="cpu"))
model.eval()

# 3. Create a fake image matching our 256x256 size
dummy_input = torch.randn(1, 3, 256, 256)

# 4. Save to ONNX
torch.onnx.export(
    model, 
    dummy_input, 
    "flood_segmentation.onnx", 
    input_names=["input_image"], 
    output_names=["output_mask"],
    opset_version=11
)
print("Conversion complete! 'flood_segmentation.onnx' is now ready.")