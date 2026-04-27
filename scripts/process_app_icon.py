#!/usr/bin/env python3
"""
App Icon Processing Script for Liuyu

This script processes a source image (PNG/JPG) to generate a macOS App Icon (.icns).
It handles:
1. Resizing to standard icon sizes (16, 32, 128, 256, 512)
2. Applying a macOS-style rounded rectangle mask (squircle)
3. Generating an .iconset directory structure
4. Compiling the .iconset into an .icns file using `iconutil`

Usage:
    python3 process_app_icon.py [input_file] [output_path]

Requirements:
    Pillow (pip install Pillow)
    macOS (for iconutil)
"""

import sys
import os
import subprocess
import shutil
from PIL import Image, ImageDraw

# Default configuration
DEFAULT_INPUT = "asset/icon.png"
DEFAULT_OUTPUT = "Sources/LiuyuLib/Resources/AppIcon.icns"
TEMP_ICONSET_DIR = "AppIcon.iconset"

# Standard macOS icon sizes
ICON_SIZES = [16, 32, 128, 256, 512]

def create_squircle_mask(size, radius_ratio=0.225):
    """
    Create a rounded rectangle mask (squircle-ish).
    macOS icons are not perfect rounded rects, but this is a good approximation.
    """
    mask = Image.new('L', size, 0)
    draw = ImageDraw.Draw(mask)
    w, h = size
    radius = int(min(w, h) * radius_ratio)
    
    # Draw rounded rectangle
    draw.rounded_rectangle([(0, 0), (w, h)], radius=radius, fill=255)
    
    return mask

def process_app_icon(input_path, output_path):
    print(f"Processing App Icon from: {input_path}")

    try:
        img = Image.open(input_path).convert("RGBA")
    except Exception as e:
        print(f"Error opening image {input_path}: {e}")
        sys.exit(1)

    # Create temporary .iconset directory
    if os.path.exists(TEMP_ICONSET_DIR):
        shutil.rmtree(TEMP_ICONSET_DIR)
    os.makedirs(TEMP_ICONSET_DIR)

    # Generate icons for each size
    for size in ICON_SIZES:
        # Normal resolution (1x)
        _generate_icon_variant(img, size, 1)
        # High resolution (2x)
        _generate_icon_variant(img, size, 2)

    # compile with iconutil
    print(f"Compiling .icns to {output_path}...")
    tmp_output_path = f"{output_path}.tmp.icns"
    try:
        if os.path.exists(tmp_output_path):
            os.remove(tmp_output_path)
        subprocess.run(["iconutil", "-c", "icns", TEMP_ICONSET_DIR, "-o", tmp_output_path], check=True)
        shutil.move(tmp_output_path, output_path)
        print("Success!")
    except subprocess.CalledProcessError as e:
        if os.path.exists(tmp_output_path):
            os.remove(tmp_output_path)
        if os.path.exists(output_path):
            print(f"Warning: iconutil failed ({e}); keeping existing {output_path}.")
            return
        print(f"Error running iconutil: {e}")
        sys.exit(1)
    finally:
        # Cleanup
        if os.path.exists(TEMP_ICONSET_DIR):
            shutil.rmtree(TEMP_ICONSET_DIR)

def _generate_icon_variant(source_img, base_size, scale):
    target_size = base_size * scale
    filename = f"icon_{base_size}x{base_size}"
    if scale == 2:
        filename += "@2x"
    filename += ".png"
    
    output_path = os.path.join(TEMP_ICONSET_DIR, filename)
    
    # Resize with high quality
    resized_img = source_img.resize((target_size, target_size), Image.Resampling.LANCZOS)
    
    # Apply mask
    mask = create_squircle_mask((target_size, target_size))
    
    # Create final image with mask
    final_img = Image.new("RGBA", (target_size, target_size), (0, 0, 0, 0))
    final_img.paste(resized_img, (0, 0), mask)
    
    final_img.save(output_path, "PNG")
    # print(f"Generated {filename}")

if __name__ == "__main__":
    # Determine paths
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    
    # Change working directory to project root for relative paths to work
    os.chdir(project_root)
    
    input_file = DEFAULT_INPUT
    if len(sys.argv) > 1:
        input_file = sys.argv[1]
        
    output_file = DEFAULT_OUTPUT
    if len(sys.argv) > 2:
        output_file = sys.argv[2]

    if not os.path.exists(input_file):
        print(f"Error: Input file not found at {input_file}")
        sys.exit(1)

    process_app_icon(input_file, output_file)
