"""Read-only audit of current demo inputs, distinct from site/ship acceptance."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.ship_rl.port_contract import validate_port_dataset


def audit() -> dict:
    paths = {"profile": "data/ports/default_port_profile.json",
             "research_dataset": "data/rl/long_beach_ais_port_ops_benchmark_v2.json",
             "mission_catalog": "data/rl/mission_rl_catalog_v1.json"}
    sources = {key: {"path": value, "sha256": hashlib.sha256((ROOT / value).read_bytes()).hexdigest()}
               for key, value in paths.items()}
    profile = json.loads((ROOT / paths["profile"]).read_text())
    dataset = json.loads((ROOT / paths["research_dataset"]).read_text())
    report = validate_port_dataset(dataset)
    missions = profile.get("navigation_missions", [])
    cases = profile.get("scenarios", {})
    rows = [{"code": m["code"], "scenario": m["scenario_key"], "route_points": len(m.get("route", [])),
             "route_ready": len(m.get("route", [])) >= 2,
             "scene_ready": m["scenario_key"] in cases,
             "speed_knots": m.get("planned_speed_knots"), "source_class": profile.get("source", {}).get("type")}
            for m in missions]
    return {"schema_version": "ship_demo_data_readiness.v1", "generated_at": datetime.now(timezone.utc).isoformat(),
            "sources": sources, "profile_name": profile["name"], "profile_missions": rows,
            "mission_count": len(rows), "profile_source": profile.get("source"),
            "research": report,
            "replacement": [
                {"input": "港区与航线", "current": "原生工程几何、7类任务航线", "replace": "user://port_profile.json；ship_port_profile_v1，核验坐标、单位和场景键"},
                {"input": "港口研究任务", "current": "Long Beach历史AIS与声明的环境/船型派生", "replace": "保持现有port dataset合同，保留URL、SHA256、时间隔离和变量来源"},
                {"input": "天气、流、潮与传感器", "current": "研究集/工程场景输入", "replace": "授权水文气象与现有传感器/船岸桥适配器，核验参考面与延迟"},
                {"input": "算法/控制器", "current": "原有冻结策略和准入回执", "replace": "按原有模型目录登记、独立测试与原生闭环验收；展示报告不改准入"}],
            "boundary": "路线配置、研究字段覆盖与现场真实性是三种口径。字段存在不表示海图、水深、船舶操纵性或气象均为现场实测。不得用模拟数据补齐海图更新、实船校准、硬件/控制验收。",
            "production_authority": False, "live_control_ready": False, "existing_models_modified": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(audit(), stream, ensure_ascii=False, indent=2, allow_nan=False)
    print(args.output.resolve())
