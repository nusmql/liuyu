#!/usr/bin/env python3
"""
Icon Processing Script for Liuyu

This script processes a source image (PNG/JPG) to generate menu bar icons
suitable for macOS applications. It handles:
1. Background removal (if not transparent)
2. Cropping to content
3. Resizing to standard macOS menu bar sizes (@1x and @2x)
4. Centering on a transparent canvas to maintain aspect ratio

Usage:
    python3 process_icon.py [input_file] [output_directory]

Requirements:
    Pillow (pip install Pillow)
"""

import sys
import os
from PIL import Image

# Default configuration
DEFAULT_INPUT = "asset/menu.jpg"
DEFAULT_OUTPUT_DIR = "Sources/LiuyuLib/Resources"
DEFAULT_OUTPUT_BASENAME = "MenuIcon"

# Target dimensions for macOS menu bar icons
TARGET_SIZE_1X = (18, 18)
TARGET_SIZE_2X = (36, 36)

def process_icon(input_path, output_dir, output_basename):
    """
    Process the input image and save generated icons to the output directory.

    Args:
        input_path (str): Path to the source image file.
        output_dir (str): Directory where generated icons will be saved.
        output_basename (str): Base filename for the output icons.
    """
    print(f"Processing icon from: {input_path}")

    try:
        # Open and convert to RGBA to ensure alpha channel exists
        img = Image.open(input_path).convert("RGBA")
    except Exception as e:
        print(f"Error opening image {input_path}: {e}")
        sys.exit(1)

    # 1. Background Removal (Optional but recommended for non-transparent sources)
    # Check if the image seems to have a solid background (e.g., white or grey)
    # For now, we assume if it's a JPG-named file (even if PNG content), it might need cleaning.
    # But since the user provided a transparent PNG (checked via 'file' command), 
    # we can skip aggressive background removal if it's already transparent.
    
    # Simple check for transparency:
    extrema = img.getextrema()
    if extrema[3][0] < 255:
        print("Image has transparency. Skipping background removal.")
    else:
        print("Image is opaque. Attempting to remove background (keeping white/bright pixels).")
        
        # Check corners to estimate background intensity
        corners = [
            img.getpixel((0, 0)),
            img.getpixel((img.width-1, 0)),
            img.getpixel((0, img.height-1)),
            img.getpixel((img.width-1, img.height-1))
        ]
        # Calculate average brightness of corners
        avg_bg = sum([sum(c[:3])/3 for c in corners]) / 4
        print(f"Estimated background brightness: {avg_bg:.1f}")
        
        threshold = 200
        if avg_bg > 200:
            # Background is very bright, increase threshold to distinguish icon
            # We assume the icon is even brighter (pure white) or distinct enough.
            # Given corners are ~210-230, let's set threshold to 240.
            threshold = 240
            print(f"Background is bright. Increasing threshold to {threshold}")

        datas = img.getdata()
        new_data = []
        for item in datas:
            # Keep white/bright pixels, make others transparent
            if item[0] > threshold and item[1] > threshold and item[2] > threshold:
                new_data.append((255, 255, 255, 255))
            else:
                new_data.append((0, 0, 0, 0))
        img.putdata(new_data)

    # 2. Crop to content (Trim transparency)
    bbox = img.getbbox()
    if bbox:
        img = img.crop(bbox)
        print(f"Cropped to content: {bbox}, New size: {img.size}")
    else:
        print("Error: Image is fully transparent (empty)!")
        sys.exit(1)

    # 3. Resize and Center
    # We want the icon to fit within 18px height (1x) and 36px (2x)
    # while maintaining aspect ratio, and centered on a square canvas.
    
    _generate_size(img, TARGET_SIZE_1X, os.path.join(output_dir, f"{output_basename}_18.png"))
    _generate_size(img, TARGET_SIZE_2X, os.path.join(output_dir, f"{output_basename}_18@2x.png"))

def _generate_size(img, target_canvas_size, output_path):
    """
    Resize image to fit within target_canvas_size and save it.
    """
    canvas_w, canvas_h = target_canvas_size
    
    # Calculate target dimensions for the content
    # We want to fit strictly within the canvas height/width
    img_w, img_h = img.size
    aspect = img_w / img_h
    
    # Determine new size constrained by canvas
    if aspect > 1:
        # Wider than tall
        new_w = canvas_w
        new_h = int(new_w / aspect)
    else:
        # Taller than wide
        new_h = canvas_h
        new_w = int(new_h * aspect)
        
    # Resize content
    img_resized = img.resize((new_w, new_h), Image.Resampling.LANCZOS)
    
    # Create transparent canvas
    final_img = Image.new("RGBA", target_canvas_size, (0, 0, 0, 0))
    
    # Center paste
    paste_x = (canvas_w - new_w) // 2
    paste_y = (canvas_h - new_h) // 2
    
    final_img.paste(img_resized, (paste_x, paste_y), img_resized)
    
    # Save
    try:
        final_img.save(output_path, "PNG")
        print(f"Saved: {output_path}")
    except Exception as e:
        print(f"Error saving {output_path}: {e}")

if __name__ == "__main__":
    # Determine paths
    # Base project directory (assuming script is in /scripts)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    
    input_file = DEFAULT_INPUT
    if len(sys.argv) > 1:
        input_file = sys.argv[1]
    
    # Resolve absolute path for input
    if not os.path.isabs(input_file):
        input_file = os.path.join(project_root, input_file)
        
    output_dir = os.path.join(project_root, DEFAULT_OUTPUT_DIR)
    if len(sys.argv) > 2:
        output_dir = sys.argv[2]
        
    if not os.path.exists(input_file):
        print(f"Error: Input file not found at {input_file}")
        sys.exit(1)
        
    if not os.path.exists(output_dir):
        print(f"Creating output directory: {output_dir}")
        os.makedirs(output_dir, exist_ok=True)
        
    process_icon(input_file, output_dir, DEFAULT_OUTPUT_BASENAME)
