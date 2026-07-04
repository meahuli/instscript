import base64
import json
import sys
from datetime import datetime
from pathlib import Path
from uuid import uuid4


def unique_output_path(directory: Path, stem: str = "output", suffix: str = ".mp4") -> Path:
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    token = uuid4().hex[:8]
    candidate = directory / f"{stem}_{timestamp}_{token}{suffix}"

    counter = 1
    while candidate.exists():
        candidate = directory / f"{stem}_{timestamp}_{token}_{counter}{suffix}"
        counter += 1

    return candidate


def pick_json_file(directory: Path) -> Path:
    json_files = sorted(
        directory.glob("*.json"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )

    if not json_files:
        raise FileNotFoundError("No .json files found in the current folder")

    return json_files[0]


def main() -> int:
    input_path = Path(sys.argv[1]) if len(sys.argv) > 1 else pick_json_file(Path.cwd())

    with input_path.open("r", encoding="utf-8") as f:
        data = json.load(f)

    try:
        video_b64 = data["output"]["video"]
    except (KeyError, TypeError) as exc:
        raise KeyError("Expected JSON shape: data['output']['video']") from exc

    if isinstance(video_b64, str) and video_b64.startswith("data:"):
        video_b64 = video_b64.split(",", 1)[1]

    video_bytes = base64.b64decode(video_b64)
    output_path = unique_output_path(Path.cwd())
    output_path.write_bytes(video_bytes)

    print(f"Saved {output_path.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
