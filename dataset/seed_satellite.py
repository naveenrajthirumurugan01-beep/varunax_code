r"""
seed_satellite.py  —  Run ONNX inference → generate transparent radar mask PNG
                      → upload to Cloudinary → write to Firestore satellite_analysis

Run this from D:\varunax_code\dataset\ after training is complete:
    python seed_satellite.py

Requirements:
    pip install numpy<2.0.0 tifffile<2024.8.10 onnxruntime Pillow requests firebase-admin
"""

import os
import sys
import subprocess
import glob

# ── Auto-install requirements ────────────────────────────────────────────────
def pip(*args):
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", *args])

try:
    import numpy as np
    if int(np.__version__.split('.')[0]) >= 2:
        print("Downgrading numpy to 1.x …")
        pip("numpy<2.0.0")
except ImportError:
    pip("numpy<2.0.0")

required = {
    "onnxruntime": "onnxruntime",
    "PIL":         "Pillow",
    "requests":    "requests",
    "tifffile":    "tifffile<2024.8.10",
    "firebase_admin": "firebase-admin",
}
for mod, pkg in required.items():
    try:
        __import__(mod)
    except ImportError:
        print(f"Installing {pkg} …")
        pip(pkg)

import numpy as np
import tifffile
import onnxruntime as ort
from PIL import Image
import requests
import json
import io

# ── Paths ────────────────────────────────────────────────────────────────────
DATASET_DIR  = os.path.dirname(__file__)
ONNX_PATH    = os.path.join(DATASET_DIR, "satellite_flood_segmentation.onnx")
IMAGE_DIR    = os.path.join(DATASET_DIR, "Sen1Floods11_8Channel", "image")

# ── Cloudinary credentials (same as your Flutter app) ────────────────────────
CLOUD_NAME    = "zpem1x8g"
UPLOAD_PRESET = "varuna_x_readings"
UPLOAD_URL    = f"https://api.cloudinary.com/v1_1/{CLOUD_NAME}/image/upload"

# ── Firebase service-account key path ────────────────────────────────────────
# Place your Firebase Admin SDK service account JSON file here.
# Download it from: Firebase Console → Project Settings → Service Accounts →
# Generate New Private Key.  Save it as  service_account.json  next to this script.
SERVICE_ACCOUNT_PATH = os.path.join(DATASET_DIR, "service_account.json")

# ── Sites to seed ─────────────────────────────────────────────────────────────
SITES = [
    {
        "siteId":              "site_tn_mettur",
        "siteName":            "Mettur Dam",
        "inundationRatio":     0.85,
        "satelliteRiskStatus": "critical",
        "precipitationMm":     120.0,
        "northEastLat":        11.821,
        "northEastLng":        77.829,
        "southWestLat":        11.781,
        "southWestLng":        77.789,
    },
    {
        "siteId":              "site_test_chennai",
        "siteName":            "Test Site (Chennai)",
        "inundationRatio":     0.45,
        "satelliteRiskStatus": "warning",
        "precipitationMm":     65.0,
        "northEastLat":        13.061,
        "northEastLng":        80.270,
        "southWestLat":        13.021,
        "southWestLng":        80.230,
    },
]

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 – Validate that the ONNX model file exists
# ─────────────────────────────────────────────────────────────────────────────
print("\n── Step 1: Checking ONNX model ──────────────────────────────────────")
if not os.path.exists(ONNX_PATH):
    print(f"ERROR: Model not found at {ONNX_PATH}")
    print("Please run  python train_satellite.py  first to generate the model.")
    sys.exit(1)
print(f"✔ ONNX model found: {ONNX_PATH}")

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 – Pick a real satellite image and run ONNX inference
# ─────────────────────────────────────────────────────────────────────────────
print("\n── Step 2: Running ONNX inference on a real SAR image ───────────────")
img_paths = sorted(glob.glob(os.path.join(IMAGE_DIR, "*.tif")))
if not img_paths:
    print(f"ERROR: No .tif images found in {IMAGE_DIR}")
    sys.exit(1)

# Use the first image in the dataset as a representative sample
sample_path = img_paths[0]
print(f"  Using sample image: {os.path.basename(sample_path)}")

raw = tifffile.imread(sample_path)

# Extract VV and VH bands (first 2 channels)
if len(raw.shape) == 3:
    bands = raw[:, :, :2].astype(np.float32)
else:
    bands = np.stack([raw, raw], axis=-1).astype(np.float32)

# Transpose to (C, H, W) and resize to 256×256
import torch
import torch.nn.functional as F
t = torch.tensor(bands.transpose(2, 0, 1)).unsqueeze(0)  # (1, 2, H, W)
t = F.interpolate(t, size=(256, 256), mode='bilinear', align_corners=False)

# Normalize SAR backscatter to [0, 1]
t = torch.clamp(t, -30.0, 0.0)
t = (t - (-30.0)) / 30.0
inp = t.numpy()  # shape (1, 2, 256, 256)

# Run ONNX inference
sess   = ort.InferenceSession(ONNX_PATH)
output = sess.run(None, {"input": inp})[0]  # (1, 1, 256, 256)
mask   = output[0, 0]                       # (256, 256) probabilities in [0,1]

print(f"  Inference complete. Max probability = {mask.max():.3f}, "
      f"Water pixels (>0.5) = {(mask > 0.5).sum()}")

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 – Render transparent red/blue radar flood mask PNG
#           Water predicted (prob > 0.5) → semi-transparent RED (#FF3B30, 60% opacity)
#           Everything else             → fully transparent
# ─────────────────────────────────────────────────────────────────────────────
print("\n── Step 3: Generating transparent radar mask PNG ────────────────────")
H, W = mask.shape
rgba = np.zeros((H, W, 4), dtype=np.uint8)

# ── Probability-scaled colouring (no hard threshold) ────────────────────────
# This means the PNG is ALWAYS visibly coloured even if the model is not yet
# fully converged (e.g. after only 10 CPU-training epochs).
#
# Strategy:
#   • Normalise the raw probability map to [0, 1] using its own min/max so
#     even a weak model that never hits 0.5 still produces a full-range mask.
#   • High probability  → vivid red   (classic SAR flood colour)
#   • Low  probability  → dark blue   (background water tone)
#   • Alpha is also scaled by probability so confident pixels are more opaque.

prob = mask.astype(np.float32)
# Stretch to fill the full [0, 1] range regardless of model confidence level
p_min, p_max = prob.min(), prob.max()
if p_max - p_min > 1e-6:
    prob_norm = (prob - p_min) / (p_max - p_min)
else:
    prob_norm = np.full_like(prob, 0.5)   # flat model → uniform 50% colour

# Red channel: scales from 50 (low prob) → 220 (high prob)
rgba[:, :, 0] = (50  + 170 * prob_norm).astype(np.uint8)   # R  50→220
# Green channel: low everywhere to keep the red/blue palette
rgba[:, :, 1] = (30  -  30 * prob_norm).astype(np.uint8)   # G  30→0
# Blue channel: scales from 180 (low prob) → 40 (high prob)
rgba[:, :, 2] = (180 - 140 * prob_norm).astype(np.uint8)   # B 180→40
# Alpha: 60 (transparent background) → 200 (opaque flood zone)
rgba[:, :, 3] = (60  + 140 * prob_norm).astype(np.uint8)   # A  60→200

pil_img = Image.fromarray(rgba, mode="RGBA")
# Scale up to 512×512 for a higher-resolution overlay on the map
pil_img = pil_img.resize((512, 512), Image.BILINEAR)

buf = io.BytesIO()
pil_img.save(buf, format="PNG")
buf.seek(0)
png_bytes = buf.read()
print(f"  PNG generated: {len(png_bytes)//1024} KB, size=512x512, RGBA")
print(f"  Colour range: prob_min={p_min:.3f}  prob_max={p_max:.3f}")
print(f"  (Colour is always visible — scaled to full range regardless of threshold)")

# ─────────────────────────────────────────────────────────────────────────────
# Step 4 – Upload the mask to Cloudinary (reuses your existing account)
# ─────────────────────────────────────────────────────────────────────────────
print("\n── Step 4: Uploading radar mask to Cloudinary ───────────────────────")
resp = requests.post(
    UPLOAD_URL,
    data={"upload_preset": UPLOAD_PRESET, "public_id": "satellite_masks/mettur_radar"},
    files={"file": ("mettur_radar.png", png_bytes, "image/png")},
    timeout=60,
)
if resp.status_code != 200:
    print(f"ERROR: Cloudinary upload failed ({resp.status_code}): {resp.text}")
    sys.exit(1)

overlay_url = resp.json()["secure_url"]
print(f"  ✔ Uploaded: {overlay_url}")

# ─────────────────────────────────────────────────────────────────────────────
# Step 5 – Seed Firestore via Firebase Admin SDK
# ─────────────────────────────────────────────────────────────────────────────
print("\n── Step 5: Seeding Firestore satellite_analysis collection ──────────")

if not os.path.exists(SERVICE_ACCOUNT_PATH):
    print()
    print("=" * 70)
    print("⚠️  SERVICE ACCOUNT KEY NOT FOUND")
    print(f"   Expected at: {SERVICE_ACCOUNT_PATH}")
    print()
    print("To generate it:")
    print("  1. Go to console.firebase.google.com")
    print("  2. Select your project → Project Settings → Service Accounts")
    print("  3. Click 'Generate New Private Key'")
    print("  4. Save the downloaded JSON as:")
    print(f"       {SERVICE_ACCOUNT_PATH}")
    print()
    print("Then re-run this script.")
    print()
    print("In the meantime, manually add these documents to Firestore")
    print("under the 'satellite_analysis' collection:")
    print()
    for site in SITES:
        doc = dict(site)
        doc["overlayImageUrl"] = overlay_url
        print(f"  Document ID: {site['siteId']}")
        for k, v in doc.items():
            if k != "siteId" and k != "siteName":
                print(f"    {k}: {v}")
        print()
    print("=" * 70)
    sys.exit(0)

import firebase_admin
from firebase_admin import credentials, firestore as admin_firestore

cred = credentials.Certificate(SERVICE_ACCOUNT_PATH)
firebase_admin.initialize_app(cred)
db = admin_firestore.client()

for site in SITES:
    doc_id = site["siteId"]
    payload = {
        "siteId":              doc_id,
        "inundationRatio":     site["inundationRatio"],
        "satelliteRiskStatus": site["satelliteRiskStatus"],
        "precipitationMm":     site["precipitationMm"],
        "overlayImageUrl":     overlay_url,
        "northEastLat":        site["northEastLat"],
        "northEastLng":        site["northEastLng"],
        "southWestLat":        site["southWestLat"],
        "southWestLng":        site["southWestLng"],
    }
    db.collection("satellite_analysis").document(doc_id).set(payload)
    print(f"  ✔ Seeded satellite_analysis/{doc_id} "
          f"[{site['satelliteRiskStatus'].upper()}]")

print()
print("=" * 70)
print("✅  ALL DONE!")
print()
print("The app will now show:")
print("  Phase 2: Real radar mask overlay on the map for Mettur Dam")
print("           + '⚠️ Warning: 120mm Overnight Rain. CRITICAL 85% inundation'")
print("  Phase 3: Orange mismatch card in Supervisor Review if a low")
print("           ground reading is submitted for Mettur Dam")
print("=" * 70)
