"""Find a concept painting's body joints and silhouette, for rigging the TRELLIS mesh made from it.

    python3 tools/fal/pose_keypoints.py <pose_landmarker.task> <image.jpg> [...]  ->  <image>_pose.json

MediaPipe Pose (pip install mediapipe; needs libEGL) gives 33 landmarks in image coordinates. Helmets
and hoods hide faces, which its person detector leans on, so thresholds are lowered. The silhouette
bounding box (pixels that differ from the plain background) maps image coordinates onto the mesh,
whose front projection has the same extent. Model:
https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_heavy/float16/latest/pose_landmarker_heavy.task
"""
import json
import sys

import numpy as np
from PIL import Image
import mediapipe as mp
from mediapipe.tasks import python as mpt
from mediapipe.tasks.python import vision

NAMES = {"nose": 0, "l_sh": 11, "r_sh": 12, "l_el": 13, "r_el": 14, "l_wr": 15, "r_wr": 16, "l_hip": 23, "r_hip": 24,
         "l_kn": 25, "r_kn": 26, "l_an": 27, "r_an": 28, "l_heel": 29, "r_heel": 30, "l_toe": 31, "r_toe": 32}


def silhouette_bbox(img):
    """Bounding box of the figure. The studio background is a vertical gradient with a vignette, so the
    background is estimated per row from both side margins and compared in the central band only
    (the vignette darkens the corners, which read as figure at a loose threshold). A row or column
    counts once enough pixels differ, which also drops the soft floor shadow."""
    a = np.asarray(img.convert("RGB"), dtype=np.float32)
    h, w = a.shape[:2]
    m = max(8, w // 40)
    bg = (np.median(a[:, :m], axis=1) + np.median(a[:, -m:], axis=1)) / 2          # (rows, 3)
    diff = np.abs(a - bg[:, None, :]).max(axis=2)
    mask = diff > 48
    band = mask[:, int(w * 0.12):int(w * 0.88)]
    rows = np.where(band.sum(axis=1) > w * 0.01)[0]
    cols = np.where(mask[int(h * 0.05):int(h * 0.95)].sum(axis=0) > h * 0.03)[0]
    return [int(cols.min()), int(rows.min()), int(cols.max()), int(rows.max())]


def main():
    model = sys.argv[1]
    opts = vision.PoseLandmarkerOptions(base_options=mpt.BaseOptions(model_asset_path=model), running_mode=vision.RunningMode.IMAGE,
                                        min_pose_detection_confidence=0.1, min_pose_presence_confidence=0.1, min_tracking_confidence=0.1)
    lm = vision.PoseLandmarker.create_from_options(opts)
    for path in sys.argv[2:]:
        im = Image.open(path).convert("RGB")
        r = lm.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=np.asarray(im)))
        if not r.pose_landmarks:
            print("NO POSE", path)
            continue
        p = r.pose_landmarks[0]
        out = {"size": [im.width, im.height], "bbox": silhouette_bbox(im),
               "joints": {k: [p[i].x * im.width, p[i].y * im.height, p[i].visibility] for k, i in NAMES.items()}}
        json.dump(out, open(path.rsplit(".", 1)[0] + "_pose.json", "w"), indent=1)
        print("POSE", path, "bbox", out["bbox"])


if __name__ == "__main__":
    main()
