import os
import subprocess
import sys
from PIL import Image

def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(repo_root)

    print("==> Rendering static/favicon.svg to PNG using qlmanage")
    svg_path = "static/favicon.svg"
    
    # Run qlmanage to convert SVG to a high-res PNG
    subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", ".", svg_path], check=True)
    
    png_path = "favicon.svg.png"
    if not os.path.exists(png_path):
        print(f"ERROR: Expected {png_path} to be generated, but it was not.")
        sys.exit(1)
        
    print(f"==> Successfully rendered to {png_path}")
    
    # Open the high-res PNG with Pillow
    img = Image.open(png_path)
    
    # --- 1. macOS Icons ---
    macos_dir = "desktop/macos/Runner/Assets.xcassets/AppIcon.appiconset"
    print(f"==> Generating macOS PNG icons in {macos_dir}")
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    
    for size in sizes:
        dest_path = os.path.join(macos_dir, f"app_icon_{size}.png")
        resized_img = img.resize((size, size), Image.Resampling.LANCZOS)
        resized_img.save(dest_path, format="PNG")
        print(f"    Saved {dest_path}")
        
    # --- 2. Windows Icons ---
    windows_ico_path = "desktop/windows/runner/resources/app_icon.ico"
    packaging_ico_path = "packaging/windows/app_icon.ico"
    
    print(f"==> Generating Windows multi-res ICO files")
    os.makedirs(os.path.dirname(windows_ico_path), exist_ok=True)
    os.makedirs(os.path.dirname(packaging_ico_path), exist_ok=True)
    
    # Save as multi-resolution .ico
    img.save(
        windows_ico_path,
        format="ICO",
        sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    )
    print(f"    Saved {windows_ico_path}")
    
    img.save(
        packaging_ico_path,
        format="ICO",
        sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    )
    print(f"    Saved {packaging_ico_path}")
    
    # --- 3. MSIX Installer Logo ---
    msix_logo_path = "desktop/assets/logo.png"
    print(f"==> Generating MSIX logo at {msix_logo_path}")
    os.makedirs(os.path.dirname(msix_logo_path), exist_ok=True)
    
    # MSIX logo (512x512 is standard)
    resized_512 = img.resize((512, 512), Image.Resampling.LANCZOS)
    resized_512.save(msix_logo_path, format="PNG")
    print(f"    Saved {msix_logo_path}")
    
    # Clean up temp png
    os.remove(png_path)
    print("==> Icon generation complete!")

if __name__ == "__main__":
    main()
