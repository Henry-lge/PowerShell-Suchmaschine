# Erzeugt Models/yolo26n.onnx für YoloObjectDetector.psm1. Nur nötig, um das
# Modell neu zu erzeugen; die Suchmaschine selbst braucht kein Python.
#
# Aufruf (in einer eigenen virtuellen Umgebung, z. B. mit uv):
#   uv venv --python 3.12 venv
#   VIRTUAL_ENV=venv uv pip install ultralytics onnx onnxslim
#   venv/bin/python export_yolo.py
#
# Schritte:
#   1. Ultralytics lädt die Gewichte von YOLO26n und exportiert sie nach ONNX,
#      ohne NMS (nms=False): YOLO26 liefert dann direkt 300 Zeilen
#      x1, y1, x2, y2, Wahrscheinlichkeit, Klasse.
#   2. Vor das Modell wird eine kleine Vorverarbeitung gesetzt: Eingang sind
#      die rohen RGB-Bytes [1, 640, 640, 3] (uint8), das Modell rechnet sie
#      selbst in Gleitkommazahlen 0..1 um und ordnet sie zu [1, 3, 640, 640].
#      In PowerShell wäre eine Schleife über 1,2 Millionen Werte pro Bild zu
#      langsam.
#
# Lizenz des Modells: AGPL-3.0 (Ultralytics).

import os

import onnx
from onnx import TensorProto, compose, helper
from ultralytics import YOLO

here = os.path.dirname(os.path.abspath(__file__))
os.chdir(here)

raw_path = YOLO("yolo26n.pt").export(format="onnx", imgsz=640, nms=False, opset=17, simplify=True)
model = onnx.load(raw_path)

preprocess = helper.make_graph(
    [
        helper.make_node("Cast", ["rgb"], ["as_float"], to=TensorProto.FLOAT),
        helper.make_node("Div", ["as_float", "scale"], ["scaled"]),
        helper.make_node("Transpose", ["scaled"], ["images"], perm=[0, 3, 1, 2]),
    ],
    "preprocess",
    [helper.make_tensor_value_info("rgb", TensorProto.UINT8, [1, 640, 640, 3])],
    [helper.make_tensor_value_info("images", TensorProto.FLOAT, [1, 3, 640, 640])],
    [helper.make_tensor("scale", TensorProto.FLOAT, [], [255.0])],
)
preprocess_model = helper.make_model(
    preprocess,
    opset_imports=model.opset_import,
    ir_version=model.ir_version,
)

merged = compose.merge_models(preprocess_model, model, io_map=[("images", "images")])
onnx.checker.check_model(merged)
onnx.save(merged, "yolo26n.onnx")

# Zwischendateien entfernen.
for leftover in ("yolo26n.pt",):
    if os.path.exists(leftover):
        os.remove(leftover)

print("Model written to", os.path.join(here, "yolo26n.onnx"))
